#!/usr/bin/env bats
# Plugins, components and keyring integrations of the -dev image. Needs IMAGE, a docker daemon, and (for the
# keyring tests) the vault and python tool images from versions/tools.yaml, plus network access for `pip install
# pykmip` inside the python container.

# The images under test come from the registry (apko publishes there, nothing is in the local docker): pull them once;
# a failed pull fails every test of the suite instead of skipping it.
setup_file() {
  load helpers
  ps_pull_images "$PS_IMAGE"
}

setup() {
  load helpers
  ps_require_dev
  unset PS_SQL_USER
  export PS_SQL_PASSWORD=x
}

teardown() {
  ps_cleanup
}

# start_server <name> [docker args...] [-- server args...]: a ready server with root password x
start_server() {
  local name=$1 cid
  shift
  cid=$(ps_start "$name" -e MYSQL_ROOT_PASSWORD=x "$@") || return 1
  ps_wait_ready "$cid" || return 1
  printf '%s\n' "$cid"
}

# plugin_status <cid> <name>
plugin_status() {
  ps_sql "$1" "SELECT plugin_status FROM information_schema.plugins WHERE plugin_name='$2'"
}

@test "plugin auth_pam" {
  cid=$(start_server pam)
  ps_sql "$cid" "INSTALL PLUGIN auth_pam SONAME 'auth_pam.so'"
  run plugin_status "$cid" auth_pam
  [ "$output" = ACTIVE ]
}

@test "plugin authentication_ldap_simple" {
  cid=$(start_server ldapsimple)
  ps_sql "$cid" "INSTALL PLUGIN authentication_ldap_simple SONAME 'authentication_ldap_simple.so'"
  run plugin_status "$cid" authentication_ldap_simple
  [ "$output" = ACTIVE ]
}

@test "plugin authentication_ldap_sasl" {
  cid=$(start_server ldapsasl)
  ps_sql "$cid" "INSTALL PLUGIN authentication_ldap_sasl SONAME 'authentication_ldap_sasl.so'"
  run plugin_status "$cid" authentication_ldap_sasl
  [ "$output" = ACTIVE ]
}

# Ruling R6: Percona Server 9.7 has no server-side authentication_kerberos / authentication_fido plugins; the official
# image ships the client plugins only (the names packages/percona-server/tests/smoke.sh asserts).
@test "client plugins shipped by the official image: kerberos, webauthn, ldap sasl" {
  cid=$(start_server clientplugins)
  plugin_dir=$(ps_sql "$cid" 'SELECT @@plugin_dir')
  for p in authentication_kerberos_client.so authentication_webauthn_client.so authentication_ldap_sasl_client.so \
    auth_pam_compat.so; do
    run ps_has_file "$cid" "${plugin_dir%/}/$p"
    [ "$status" -eq 0 ]
  done
}

@test "rocksdb: INSTALL PLUGIN" {
  cid=$(start_server rocks)
  ps_sql "$cid" "INSTALL PLUGIN rocksdb SONAME 'ha_rocksdb.so'"
  ps_sql "$cid" 'CREATE DATABASE r; CREATE TABLE r.t (id INT PRIMARY KEY, v INT) ENGINE=ROCKSDB; INSERT INTO r.t VALUES (1, 2)'
  run ps_sql "$cid" "SELECT support FROM information_schema.engines WHERE engine='ROCKSDB'"
  [ "$output" = YES ]
  run ps_sql "$cid" 'SELECT v FROM r.t'
  [ "$output" = 2 ]
}

@test "rocksdb: INIT_ROCKSDB=1 enables it at initialisation" {
  cid=$(start_server initrocks -e INIT_ROCKSDB=1)
  run ps_sql "$cid" "SELECT support FROM information_schema.engines WHERE engine='ROCKSDB'"
  [ "$output" = YES ]
  # still enabled after a restart (ps-admin persists it in the config)
  ps_docker restart "$cid" > /dev/null
  ps_wait_ready "$cid"
  run ps_sql "$cid" "SELECT support FROM information_schema.engines WHERE engine='ROCKSDB'"
  [ "$output" = YES ]
}

@test "encryption UDF component" {
  cid=$(start_server encudf)
  ps_sql "$cid" "INSTALL COMPONENT 'file://component_encryption_udf'"
  run ps_sql "$cid" "SELECT create_asymmetric_priv_key('RSA', 1024) IS NOT NULL"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
}

@test "mecab full-text parser" {
  cid=$(start_server mecab -- --innodb-ft-min-token-size=1)
  ps_sql "$cid" "INSTALL PLUGIN mecab SONAME 'libpluginmecab.so'"
  # the configuration the plugin reads must be in the image: mecab_rc_file has no default (NULL), and libmecab then
  # reads its compiled-in /etc/mecabrc, whose dicdir must hold the ipadic dictionary
  rc=$(ps_sql "$cid" 'SELECT @@mecab_rc_file')
  [[ $rc != NULL ]] || rc=/etc/mecabrc
  ps_has_file "$cid" "$rc"
  ps_has_file "$cid" /usr/lib/mecab/dic/ipadic/dicrc
  ps_has_file "$cid" /usr/lib/mecab/dic/ipadic/sys.dic
  ps_sql "$cid" "CREATE DATABASE m; CREATE TABLE m.ft (id INT PRIMARY KEY, body TEXT, FULLTEXT KEY (body) WITH PARSER mecab) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4; INSERT INTO m.ft VALUES (1, '日本語のテキストです'), (2, 'English only')"
  run ps_sql "$cid" "SELECT COUNT(*) FROM m.ft WHERE MATCH(body) AGAINST('日本語' IN BOOLEAN MODE)"
  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  # a second token of the same row
  run ps_sql "$cid" "SELECT COUNT(*) FROM m.ft WHERE MATCH(body) AGAINST('テキスト' IN BOOLEAN MODE)"
  [ "$output" = 1 ]
}

@test "JavaScript stored function" {
  cid=$(start_server js)
  ps_sql "$cid" "INSTALL COMPONENT 'file://component_js_lang'"
  ps_sql "$cid" "GRANT CREATE_JS_ROUTINE ON *.* TO 'root'@'localhost'"
  # shellcheck disable=SC2016 # $$ is the SQL routine-body delimiter
  ps_sql "$cid" 'CREATE DATABASE j; CREATE FUNCTION j.f() RETURNS INT DETERMINISTIC LANGUAGE JS AS $$ return 1+1 $$'
  run ps_sql "$cid" 'SELECT j.f()'
  [ "$output" = 2 ]
}

# keyring_roundtrip <cid> <component>: encrypt a table, restart the container, read the data back, and check the
# component is active.
keyring_roundtrip() {
  local cid=$1 comp=$2
  run ps_sql "$cid" "SELECT status_value FROM performance_schema.keyring_component_status WHERE status_key='Component_status'"
  [ "$status" -eq 0 ]
  [ "$output" = Active ]
  ps_sql "$cid" "CREATE DATABASE k; CREATE TABLE k.t (id INT PRIMARY KEY, v VARCHAR(32)) ENCRYPTION='Y'; INSERT INTO k.t VALUES (1, 'secret-$comp')"
  run ps_sql "$cid" "SELECT create_options FROM information_schema.tables WHERE table_schema='k' AND table_name='t'"
  [[ $output == *ENCRYPTION* ]]
  ps_docker restart "$cid" > /dev/null
  ps_wait_ready "$cid"
  run ps_sql "$cid" 'SELECT v FROM k.t WHERE id=1'
  [ "$status" -eq 0 ]
  [ "$output" = "secret-$comp" ]
}

@test "component_keyring_vault against a vault dev server" {
  net=$(ps_network vault)
  ps_track containers "$(ps_prefix)-vault"
  ps_docker run -d --name "$(ps_prefix)-vault" --network "$net" --network-alias vault --cap-add IPC_LOCK \
    -e VAULT_DEV_ROOT_TOKEN_ID=ps-test-token -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
    "$(ps_tool_image vault)" server -dev > /dev/null
  vol=$(ps_volume vaultdata)
  cid=$(start_server vaultps --network "$net" -v "$vol:/var/lib/mysql")
  # components are configured through local files in the datadir (the image ships mysqld.my / .cnf with
  # read_local_manifest / read_local_config); the datadir has to be initialised first
  ps_docker stop "$cid" > /dev/null
  ps_seed_datadir "$vol" \
    mysqld.my '{"components": "file://component_keyring_vault"}' \
    component_keyring_vault.cnf '{"timeout": 15, "vault_url": "http://vault:8200", "secret_mount_point": "secret", "secret_mount_point_version": "AUTO", "token": "ps-test-token"}'
  ps_docker start "$cid" > /dev/null
  ps_wait_ready "$cid"
  keyring_roundtrip "$cid" vault
}

# Throwaway CA, server and client certificates, generated at test time in the wolfi_sdk image.
make_kmip_certs() {
  local vol=$1
  # shellcheck disable=SC2016 # the script expands in the container
  ps_docker run --rm --user 0 -v "$vol:/certs" --entrypoint sh "$(ps_tool_image wolfi_sdk)" -ec '
    cd /certs
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test-ca -keyout ca.key -out ca.crt
    for n in server client; do
      openssl req -newkey rsa:2048 -nodes -subj /CN=kmip-$n -keyout $n.key -out $n.csr
      printf "subjectAltName=DNS:kmip\nextendedKeyUsage=serverAuth,clientAuth\n" > $n.ext
      openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile $n.ext -out $n.crt
    done
    chmod 644 *.crt *.key' > /dev/null
}

@test "component_keyring_kmip against a PyKMIP server" {
  net=$(ps_network kmip)
  certs=$(ps_volume kmipcerts)
  make_kmip_certs "$certs"
  conf='[server]
hostname=0.0.0.0
port=5696
certificate_path=/certs/server.crt
key_path=/certs/server.key
ca_path=/certs/ca.crt
auth_suite=TLS1.2
enable_tls_client_auth=True
policy_path=/tmp/policies
logging_level=DEBUG
database_path=/tmp/pykmip.db'
  ps_track containers "$(ps_prefix)-kmip"
  # shellcheck disable=SC2016 # the script expands in the container
  ps_docker run -d --name "$(ps_prefix)-kmip" --network "$net" --network-alias kmip -v "$certs:/certs:ro" \
    -e "PYKMIP_CONF=$conf" --entrypoint sh "$(ps_tool_image python)" -c '
      set -e
      mkdir -p /tmp/policies
      pip install --quiet --no-cache-dir "pykmip==0.10.0" "sqlalchemy<2" "setuptools<81"
      printf "%s\n" "$PYKMIP_CONF" > /tmp/server.conf
      # PyKMIP 0.10.0 (the last release) calls ssl.wrap_socket, removed in Python 3.12: restore it on top of
      # SSLContext (sitecustomize is imported at interpreter start)
      mkdir -p /tmp/shim
      cat > /tmp/shim/sitecustomize.py <<"PY"
import ssl

if not hasattr(ssl, "wrap_socket"):
    def wrap_socket(sock, keyfile=None, certfile=None, server_side=False, cert_reqs=ssl.CERT_NONE,
                    ssl_version=None, ca_certs=None, do_handshake_on_connect=True,
                    suppress_ragged_eofs=True, ciphers=None):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER if server_side else ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.verify_mode = cert_reqs
        if certfile:
            ctx.load_cert_chain(certfile, keyfile)
        if ca_certs:
            ctx.load_verify_locations(ca_certs)
        if ciphers:
            ctx.set_ciphers(ciphers)
        return ctx.wrap_socket(sock, server_side=server_side, do_handshake_on_connect=do_handshake_on_connect,
                               suppress_ragged_eofs=suppress_ragged_eofs)

    ssl.wrap_socket = wrap_socket
PY
      PYTHONPATH=/tmp/shim exec pykmip-server -f /tmp/server.conf' > /dev/null
  # wait for the KMIP port
  up=
  for _ in $(seq 1 90); do
    if ps_docker run --rm --network "$net" --entrypoint python3 "$(ps_tool_image python)" -c \
      'import socket; socket.create_connection(("kmip", 5696), 2).close()' > /dev/null 2>&1; then
      up=1
      break
    fi
    sleep 2
  done
  if [ -z "$up" ]; then
    ps_docker logs "$(ps_prefix)-kmip" >&2
    false
  fi
  vol=$(ps_volume kmipdata)
  # shellcheck source=../fixtures/upgrade-lib.bash
  source "$PS_ROOT/tests/fixtures/upgrade-lib.bash"
  cid=$(start_server kmipps --network "$net" -v "$vol:/var/lib/mysql" -v "$certs:/kmip-certs:ro" \
    -v "$(keyring_global_mount component_keyring_kmip)")
  ps_docker stop "$cid" > /dev/null
  ps_seed_datadir "$vol" \
    mysqld.my '{"components": "file://component_keyring_kmip"}' \
    component_keyring_kmip.cnf '{"server_addr": "kmip", "server_port": "5696", "client_ca": "/kmip-certs/client.crt", "client_key": "/kmip-certs/client.key", "server_ca": "/kmip-certs/ca.crt"}'
  ps_docker start "$cid" > /dev/null
  ps_wait_ready "$cid"
  keyring_roundtrip "$cid" kmip
}

# OpenSSL ruling (2026-11-15): mysqld links OpenSSL 3.6 (libssl.so.3), Wolfi's libldap/libk5crypto link
# OpenSSL 4 (libssl.so.4). Both load into one process; distinct symbol versions (OPENSSL_3.x vs OPENSSL_4.0.0) keep
# them apart. TLS must keep working once a plugin has pulled OpenSSL 4 in.
@test "TLS with OpenSSL 3 and OpenSSL 4 both loaded (LDAP SASL plugin)" {
  cid=$(start_server tls34)
  tls() {
    ps_docker exec -i -e MYSQL_PWD=x "$cid" mysql --no-defaults -N -B -uroot -h127.0.0.1 --ssl-mode=REQUIRED \
      -e "SELECT variable_value FROM performance_schema.session_status WHERE variable_name='Ssl_version'"
  }
  run tls
  [ "$status" -eq 0 ]; [[ $output == TLSv1.[23] ]]
  ps_sql "$cid" "INSTALL PLUGIN authentication_ldap_sasl SONAME 'authentication_ldap_sasl.so'"
  maps=$(ps_docker exec "$cid" cat /proc/1/maps)
  [[ $maps == *libssl.so.3* ]]
  [[ $maps == *libssl.so.4* ]]
  run tls
  [ "$status" -eq 0 ]; [[ $output == TLSv1.[23] ]]
  run ps_sql "$cid" "SELECT SHA2('abc', 256)"
  [ "$output" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ]
}
