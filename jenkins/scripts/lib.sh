#!/usr/bin/env bash
# Helpers shared by the Jenkins scripts, meant to be sourced after scripts/lib/common.sh (run from the repo root).

# ci_tool <name> [docker-run-args...] -- <cmd args...>: like `tool`, for an image pinned in jenkins/tools.yaml.
ci_tool() { TOOLS_FILE=jenkins/tools.yaml tool "$@"; }

# images_list: the IMAGES of mk/images.mk, in build order.
images_list() {
  # shellcheck disable=SC2016 # $(IMAGES) is for make
  ${MAKE_CMD:-make} --no-print-directory -s -f mk/images.mk -f - print-images <<< 'print-images: ; @echo $(IMAGES)'
}

# image_repo <image>: the registry repository of an image (the -dev image lives in percona-server).
image_repo() {
  case $1 in
    percona-server | percona-server-dev) echo percona-server ;;
    *) echo "$1" ;;
  esac
}

# known_image <image>: 0 if the image is in IMAGES.
known_image() {
  local i
  for i in $(images_list); do [[ $i == "$1" ]] && return 0; done
  return 1
}
