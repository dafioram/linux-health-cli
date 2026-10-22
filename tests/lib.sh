# shellcheck shell=bash
# shared helpers for the test scripts (sourced, not run)
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER=$ROOT/install-healthcheck.sh
FAILS=0

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; FAILS=$((FAILS+1)); }
check() {  # usage: check "description" command...
  local d=$1; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}
section() { echo; echo "== $*"; }
finish() {
  echo
  if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) failed"; exit 1; fi
  echo "all checks passed"
}

# print one embedded heredoc (HC_EOF, HOOK_EOF) from the installer
extract() { awk -v t="$1" '$0 ~ "<<.?"t".?$" {f=1; next} $0 == t {f=0} f' "$INSTALLER"; }
