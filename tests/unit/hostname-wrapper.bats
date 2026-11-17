#!/usr/bin/env bats
# packages/percona-fluentbit-docker-scripts/files/hostname: `hostname -I` from `ip -o addr show` (stubbed), anything
# else handed to the real hostname (HOSTNAME_BIN, stubbed).

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  H="$ROOT/packages/percona-fluentbit-docker-scripts/files/hostname"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/ip" <<'STUB'
#!/bin/sh
[ "$*" = "-o addr show" ] || exit 9
cat <<'EOF'
1: lo    inet 127.0.0.1/8 scope host lo\       valid_lft forever preferred_lft forever
1: lo    inet6 ::1/128 scope host noprefixroute \       valid_lft forever preferred_lft forever
2: eth0    inet 10.42.0.17/24 brd 10.42.0.255 scope global eth0\       valid_lft forever preferred_lft forever
2: eth0    inet6 fd00:10:42::11/64 scope global \       valid_lft forever preferred_lft forever
2: eth0    inet6 fe80::a8bb:ccff:fedd:eeff/64 scope link \       valid_lft forever preferred_lft forever
3: net1    inet 192.168.7.3/24 brd 192.168.7.255 scope global net1\       valid_lft forever preferred_lft forever
EOF
STUB
  printf '#!/bin/sh\necho "real:$*"\n' > "$BATS_TEST_TMPDIR/bin/real-hostname"
  chmod +x "$BATS_TEST_TMPDIR/bin/ip" "$BATS_TEST_TMPDIR/bin/real-hostname"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOSTNAME_BIN="$BATS_TEST_TMPDIR/bin/real-hostname"
}

@test "-I: every address but loopback and link-local, interface order, space-terminated" {
  run "$H" -I
  [ "$status" -eq 0 ]
  [ "$output" = "10.42.0.17 fd00:10:42::11 192.168.7.3 " ]
  run "$H" --all-ip-addresses
  [ "$output" = "10.42.0.17 fd00:10:42::11 192.168.7.3 " ]
}

@test "-I: the first field is the pod address, as postrotate-mysql.sh reads it" {
  read -r ip _ <<< "$("$H" -I)"
  [ "$ip" = 10.42.0.17 ]
  [ "$("$H" -I | awk '{print $1}')" = 10.42.0.17 ]
}

@test "-I with only loopback prints an empty line" {
  printf '#!/bin/sh\necho "1: lo    inet 127.0.0.1/8 scope host lo"\n' > "$BATS_TEST_TMPDIR/bin/ip"
  run "$H" -I
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "other arguments go to the real hostname unchanged" {
  run "$H"
  [ "$output" = "real:" ]
  run "$H" -s
  [ "$output" = "real:-s" ]
  run "$H" -I -s
  [ "$output" = "real:-I -s" ]
}

@test "a failing ip fails -I" {
  printf '#!/bin/sh\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/ip"
  run "$H" -I
  [ "$status" -ne 0 ]
}
