#!/bin/bash
# linux/docs-grep.sh <origin> <word> -- numbered lines of the room API's public docs that hold <word> (no token needed).
main() {
  local origin=${1:?origin} word=${2:?word}
  curl -sS -m 30 "$origin/api" </dev/null | grep -n -i -F -- "$word" | cut -c1-300 | head -n 60
  return 0
}
main "$@"; exit $?
