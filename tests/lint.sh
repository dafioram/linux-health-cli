#!/bin/bash
# Static checks: syntax and shellcheck for the installer and the scripts it embeds.
set -u
. "$(dirname "$0")/lib.sh"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

extract HC_EOF > "$TMPD/healthcheck"
extract HOOK_EOF > "$TMPD/healthcheck-hook.sh"

section "embedded scripts were found"
check "collector extracted" test -s "$TMPD/healthcheck"
check "login hook extracted" test -s "$TMPD/healthcheck-hook.sh"

section "syntax"
check "installer (bash -n)" bash -n "$INSTALLER"
check "collector (bash -n)" bash -n "$TMPD/healthcheck"
# the hook is sourced by /etc/profile, which may be dash on Debian
for sh in sh dash bash; do
  command -v "$sh" >/dev/null || continue
  check "login hook ($sh -n)" "$sh" -n "$TMPD/healthcheck-hook.sh"
done

section "shellcheck"
if command -v shellcheck >/dev/null; then
  check "installer" shellcheck -S warning "$INSTALLER"
  check "collector" shellcheck -S warning -s bash "$TMPD/healthcheck"
  check "login hook (POSIX sh)" shellcheck -S warning -s sh "$TMPD/healthcheck-hook.sh"
  check "test scripts" shellcheck -S warning -x "$ROOT"/tests/*.sh
else
  fail "shellcheck not installed"
fi

finish
