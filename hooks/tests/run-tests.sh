#!/usr/bin/env bash
# Runs every hook test suite. Needs bash 3.2+, git, jq and python3; nothing else. Exit 0 when all pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
for tool in bash git jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing: $tool"; exit 2; }
done
STATUS=0
for t in "$HERE"/test-*.sh; do
  echo "== $(basename "$t")"
  bash "$t" || STATUS=1
  echo
done
[ "$STATUS" -eq 0 ] && echo "all suites passed" || echo "a suite failed"
exit "$STATUS"
