#!/bin/bash
# linux/docs-lines.sh <origin> <from> <to> -- prints lines FROM..TO of the room API's public docs (no token needed).
main() {
  local origin=${1:?origin} from=${2:?from} to=${3:?to}
  curl -sS -m 30 "$origin/api" </dev/null | sed -n "${from},${to}p" | cut -c1-300
  return 0
}
main "$@"; exit $?
