#!/usr/bin/env bash
# Bring up the local kernel (:19433) and scheduler (:28433).
#
# Idempotent: whatever is already listening is left alone. Each service is
# started with `setsid nohup` so it survives the shell that launched it —
# a plain `&` dies with the caller's process group, which is why the desktop
# shell kept reporting "cannot connect to 127.0.0.1:28433".
#
# Logs: ~/.trha/logs/{kernel,scheduler}.log (TRHA_LOG_DIR overrides)
set -euo pipefail
cd "$(dirname "$0")/.."

KERNEL_PORT=${TRHA_KERNEL_PORT:-19433}
SCHED_PORT=${TRHA_PORT:-28433}
# Same place the CLI writes its own logs: these must survive a reboot and
# belong with the rest of the state, not in /tmp.
LOG_DIR=${TRHA_LOG_DIR:-$HOME/.trha/logs}
mkdir -p "$LOG_DIR"

listening() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

trha_bin() {
  if command -v trha >/dev/null 2>&1; then
    command -v trha
  else
    cabal list-bin trha:exe:trha 2>/dev/null | tail -1
  fi
}

wait_http() { # url, attempts
  local url=$1 tries=${2:-40}
  for _ in $(seq 1 "$tries"); do
    if curl -sk -o /dev/null --max-time 1 "$url"; then return 0; fi
    sleep 0.5
  done
  return 1
}

start_kernel() {
  if listening "$KERNEL_PORT"; then
    echo "kernel:    already listening on :$KERNEL_PORT"
    return 0
  fi
  local bin
  bin=$(trha_bin)
  if [ ! -x "$bin" ]; then
    echo "kernel:    no trha binary (run: cabal build trha:exe:trha)" >&2
    return 1
  fi
  setsid nohup "$bin" serve --kernel-port "$KERNEL_PORT" \
    >"$LOG_DIR/kernel.log" 2>&1 </dev/null &
  echo "kernel:    started ($bin) on :$KERNEL_PORT"
}

start_scheduler() {
  if listening "$SCHED_PORT"; then
    echo "scheduler: already listening on :$SCHED_PORT"
    return 0
  fi
  local dir=packages/scheduler
  if [ ! -f "$dir/dist/cli.js" ]; then
    ( cd "$dir" && npx tsc >/dev/null )
  fi
  ( cd "$dir" && setsid nohup node dist/cli.js \
      >"$LOG_DIR/scheduler.log" 2>&1 </dev/null & )
  echo "scheduler: started on :$SCHED_PORT"
}

start_kernel
start_scheduler

wait_http "http://127.0.0.1:$KERNEL_PORT/health" \
  || { echo "kernel:    health check failed (see $LOG_DIR/kernel.log)" >&2; exit 1; }
wait_http "https://127.0.0.1:$SCHED_PORT/health" \
  || { echo "scheduler: health check failed (see $LOG_DIR/scheduler.log)" >&2; exit 1; }

echo "kernel:    http://127.0.0.1:$KERNEL_PORT/health   ok"
echo "scheduler: https://127.0.0.1:$SCHED_PORT/health  ok"
