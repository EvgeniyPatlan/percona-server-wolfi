#!/usr/bin/env bash
# render.sh <template> <vars-file> <out>: replace @@key@@ with vars_get values.
# The output file is only written once every placeholder has been resolved.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

(($# == 3)) || die "usage: render.sh <template> <vars-file> <out>"
tmpl=$1 vars=$2 out=$3
[[ -r $tmpl ]] || die "cannot read template: $tmpl"

# trailing sentinel keeps final newlines through $(...)
content=$(
  cat "$tmpl"
  printf x
)
content=${content%x}

while IFS= read -r key; do
  [[ -n $key ]] || continue
  val=$(vars_get "$vars" "$key") || die "template $tmpl: unknown key '$key' in $vars"
  esc=$(printf '%s' "$val" | sed -e 's/[\\/&]/\\&/g')
  content=$(
    printf '%s' "$content" | sed -e "s/@@${key}@@/${esc}/g"
    printf x
  )
  content=${content%x}
done < <(grep -oE '@@[a-z0-9_]+@@' "$tmpl" | sort -u | sed -e 's/^@@//; s/@@$//' || true)

if left=$(printf '%s' "$content" | grep -oE '@@[a-z0-9_]+@@' | head -n1) && [[ -n $left ]]; then
  die "unresolved placeholder after render: $left"
fi
mkdir -p "$(dirname "$out")"
printf '%s' "$content" > "$out"
