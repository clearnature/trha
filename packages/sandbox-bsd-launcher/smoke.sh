#!/bin/sh
# Contract smoke tests for the BSD launcher — runnable on any host.
#
# The argument shapes asserted here are the ones the Haskell renderers emit
# (Infrastructure.Sandbox.Backend.FreeBSD / OpenBSD); SandboxBsdSpec pins the
# same shapes from the Haskell side.
set -eu

BIN=./trha-sandbox-bsd
fail=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=1; }

# 1) FreeBSD shape.
out=$("$BIN" --workspace /tmp/ws --scratch /tmp/scratch --policy workspace-write \
      --network off --dry-run -- sh -c 'echo hi')
printf '%s\n' "$out" | grep -q '^workspace: /tmp/ws$' \
  && ok "freebsd workspace parsed" || bad "freebsd workspace parsed"
printf '%s\n' "$out" | grep -q '^policy: workspace-write$' \
  && ok "freebsd policy parsed" || bad "freebsd policy parsed"
printf '%s\n' "$out" | grep -q '^command: sh -c echo hi$' \
  && ok "freebsd command parsed" || bad "freebsd command parsed"

# 2) OpenBSD shape.
out=$("$BIN" --pledge 'stdio rpath wpath cpath proc exec' \
      --unveil /ws:rw --unveil /scratch:rw --unveil /etc:r --unveil /usr:r \
      --unveil /bin:r --unveil /sbin:r --dry-run -- sh -c 'echo hi')
printf '%s\n' "$out" | grep -q '^pledge: stdio rpath wpath cpath proc exec$' \
  && ok "openbsd pledge parsed" || bad "openbsd pledge parsed"
printf '%s\n' "$out" | grep -q '^unveil: /etc:r$' \
  && ok "openbsd unveil parsed" || bad "openbsd unveil parsed"
n=$(printf '%s\n' "$out" | grep -c '^unveil: ')
[ "$n" -eq 6 ] && ok "openbsd unveil count = 6" || bad "openbsd unveil count = 6 (got $n)"

# 3) The launcher never becomes a passthrough off-BSD.
case "$(uname -s)" in
  FreeBSD|OpenBSD) ok "platform check skipped on $(uname -s)" ;;
  *)
    if "$BIN" --workspace /tmp --scratch /tmp --policy read-only --network off -- true >/dev/null 2>&1; then
      bad "ran unconfined off-BSD"
    else
      ok "refused to run unconfined off-BSD"
    fi
    ;;
esac

# 4) Malformed input is rejected, not half-parsed.
if "$BIN" --policy read-only -- >/dev/null 2>&1; then
  bad "accepted a missing command"
else
  ok "rejected a missing command"
fi
if "$BIN" --unveil /tmp --dry-run -- true >/dev/null 2>&1; then
  bad "accepted --unveil without :perms"
else
  ok "rejected --unveil without :perms"
fi

exit $fail
