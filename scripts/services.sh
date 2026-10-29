#!/usr/bin/env bash
# Register trha's kernel (:19433) and scheduler (:28433) as *user* services so
# they survive the shell that started them.
#
#   scripts/services.sh install | uninstall | start | stop | status | logs
#
# User-level only (systemd --user on Linux, launchd LaunchAgent on macOS): no
# sudo, nothing touches /etc or /Library. Windows is out of scope for now
# (docs/plans/sandbox-decisions.md ADR-007: P4, not before it is needed) —
# `trha` starts both on demand there too (Core.Bootstrap).
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=$(pwd)
KERNEL_PORT=${TRHA_KERNEL_PORT:-19433}
SCHED_PORT=${TRHA_PORT:-28433}
DRY_RUN=${DRY_RUN:-0}

NODE=$(command -v node || true)
TRHA_BIN=$(command -v trha 2>/dev/null || cabal list-bin trha:exe:trha 2>/dev/null | tail -1 || true)

say() { printf '%s\n' "$*"; }
die() { printf 'services: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi
}

need_binaries() {
  [ -x "${TRHA_BIN:-}" ] || die "no trha binary (run: cabal build trha:exe:trha)"
  [ -n "$NODE" ] || die "node not found in PATH"
  [ -f "$REPO/packages/scheduler/dist/cli.js" ] \
    || die "scheduler not built (run: (cd packages/scheduler && npx tsc))"
}

# ---------------------------------------------------------------- templates
kernel_unit() {
  cat <<EOF
[Unit]
Description=trha kernel (:$KERNEL_PORT)
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO
ExecStart=$TRHA_BIN serve --kernel-port $KERNEL_PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

scheduler_unit() {
  cat <<EOF
[Unit]
Description=trha scheduler (:$SCHED_PORT)
After=network.target trha-kernel.service
Wants=trha-kernel.service

[Service]
Type=simple
WorkingDirectory=$REPO/packages/scheduler
ExecStart=$NODE $REPO/packages/scheduler/dist/cli.js
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
}

kernel_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.clearnature.trha.kernel</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TRHA_BIN</string><string>serve</string>
    <string>--kernel-port</string><string>$KERNEL_PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/tmp/trha-kernel.log</string>
  <key>StandardErrorPath</key><string>/tmp/trha-kernel.err.log</string>
</dict>
</plist>
EOF
}

scheduler_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.clearnature.trha.scheduler</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string><string>$REPO/packages/scheduler/dist/cli.js</string>
  </array>
  <key>WorkingDirectory</key><string>$REPO/packages/scheduler</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>/tmp/trha-scheduler.log</string>
  <key>StandardErrorPath</key><string>/tmp/trha-scheduler.err.log</string>
</dict>
</plist>
EOF
}

# ------------------------------------------------------------------- Linux
UNIT_DIR="$HOME/.config/systemd/user"

linux_install() {
  need_binaries
  run mkdir -p "$UNIT_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] write $UNIT_DIR/trha-kernel.service"
    say "[dry-run] write $UNIT_DIR/trha-scheduler.service"
  else
    kernel_unit >"$UNIT_DIR/trha-kernel.service"
    scheduler_unit >"$UNIT_DIR/trha-scheduler.service"
  fi
  run systemctl --user daemon-reload
  run systemctl --user enable --now trha-kernel.service trha-scheduler.service
  say "installed: $UNIT_DIR/trha-{kernel,scheduler}.service (user units, no sudo)"
}

linux_uninstall() {
  run systemctl --user disable --now trha-scheduler.service trha-kernel.service || true
  run rm -f "$UNIT_DIR/trha-kernel.service" "$UNIT_DIR/trha-scheduler.service"
  run systemctl --user daemon-reload
  say "uninstalled trha user units"
}

linux_status() {
  systemctl --user --no-pager status trha-kernel.service trha-scheduler.service 2>&1 | head -30 || true
  say ""
  say "health:"
  curl -s -o /dev/null -w "  kernel    :$KERNEL_PORT  %{http_code}\n" --max-time 2 \
    "http://127.0.0.1:$KERNEL_PORT/health" || say "  kernel    :$KERNEL_PORT  down"
  curl -sk -o /dev/null -w "  scheduler :$SCHED_PORT  %{http_code}\n" --max-time 2 \
    "https://127.0.0.1:$SCHED_PORT/health" || say "  scheduler :$SCHED_PORT  down"
}

# ------------------------------------------------------------------- macOS
AGENT_DIR="$HOME/Library/LaunchAgents"

mac_install() {
  need_binaries
  run mkdir -p "$AGENT_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    say "[dry-run] write $AGENT_DIR/com.clearnature.trha.{kernel,scheduler}.plist"
  else
    kernel_plist >"$AGENT_DIR/com.clearnature.trha.kernel.plist"
    scheduler_plist >"$AGENT_DIR/com.clearnature.trha.scheduler.plist"
  fi
  run launchctl unload "$AGENT_DIR/com.clearnature.trha.kernel.plist" 2>/dev/null || true
  run launchctl unload "$AGENT_DIR/com.clearnature.trha.scheduler.plist" 2>/dev/null || true
  run launchctl load "$AGENT_DIR/com.clearnature.trha.kernel.plist"
  run launchctl load "$AGENT_DIR/com.clearnature.trha.scheduler.plist"
  say "installed: $AGENT_DIR/com.clearnature.trha.*.plist (LaunchAgents)"
}

mac_uninstall() {
  run launchctl unload "$AGENT_DIR/com.clearnature.trha.scheduler.plist" 2>/dev/null || true
  run launchctl unload "$AGENT_DIR/com.clearnature.trha.kernel.plist" 2>/dev/null || true
  run rm -f "$AGENT_DIR/com.clearnature.trha.kernel.plist" \
    "$AGENT_DIR/com.clearnature.trha.scheduler.plist"
  say "uninstalled trha LaunchAgents"
}

mac_status() {
  launchctl list | grep -i "clearnature.trha" || say "(no trha agents loaded)"
  say ""
  curl -s -o /dev/null -w "  kernel    :$KERNEL_PORT  %{http_code}\n" --max-time 2 \
    "http://127.0.0.1:$KERNEL_PORT/health" || say "  kernel    :$KERNEL_PORT  down"
  curl -sk -o /dev/null -w "  scheduler :$SCHED_PORT  %{http_code}\n" --max-time 2 \
    "https://127.0.0.1:$SCHED_PORT/health" || say "  scheduler :$SCHED_PORT  down"
}

# ------------------------------------------------------------------ dispatch
os=$(uname -s)
action=${1:-}

case "$os:$action" in
  Linux:install)      linux_install ;;
  Linux:uninstall)    linux_uninstall ;;
  Linux:status)       linux_status ;;
  Linux:start)        run systemctl --user start trha-kernel.service trha-scheduler.service ;;
  Linux:stop)         run systemctl --user stop trha-scheduler.service trha-kernel.service ;;
  Linux:logs)         journalctl --user -u trha-kernel -u trha-scheduler -n 40 --no-pager ;;
  Linux:dump|Darwin:dump)
    dir=${TRHA_DUMP_DIR:-$REPO}
    kernel_unit >"$dir/trha-kernel.service" 2>/dev/null || kernel_plist >"$dir/com.clearnature.trha.kernel.plist"
    scheduler_unit >"$dir/trha-scheduler.service" 2>/dev/null || scheduler_plist >"$dir/com.clearnature.trha.scheduler.plist"
    say "wrote service definitions to $dir" ;;
  Darwin:install)     mac_install ;;
  Darwin:uninstall)   mac_uninstall ;;
  Darwin:status)      mac_status ;;
  Darwin:start)       run launchctl load "$AGENT_DIR/com.clearnature.trha.kernel.plist" ;;
  Darwin:stop)        run launchctl unload "$AGENT_DIR/com.clearnature.trha.kernel.plist" ;;
  Darwin:logs)        tail -40 /tmp/trha-kernel.log /tmp/trha-scheduler.log ;;
  *)
    die "unsupported: $os ${action:-<none>}
Windows is P4 by ADR-007 (docs/plans/sandbox-decisions.md); run \`trha\` and
Core.Bootstrap starts both services on demand, or register a Task Scheduler
entry pointing at \`trha serve --kernel-port $KERNEL_PORT\` yourself.
usage: scripts/services.sh {install|uninstall|start|stop|status|logs}"
    ;;
esac
