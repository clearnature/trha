#!/usr/bin/env bash
# P-08: run every probe executable and aggregate exit codes.
#
# Why: `trha.cabal` has ~25 probe executables, but nothing runs them as a
# group — a broken probe silently stays green.  This script runs them,
# prints PASS/FAIL/SKIP, and exits non-zero if any FAIL.
#
# Usage:
#   scripts/run-probes.sh                 # normal probes (heavy ones skipped)
#   PROBES_ALL=1 scripts/run-probes.sh    # include braintoken/real60/b1lm
#   PROBE_TIMEOUT=300 scripts/run-probes.sh
#
# Notes:
#   - GPU probes are skipped when /dev/dri is absent (CI runners).
#   - Heavy probes (5GB weights / ~2min cold start) are opt-in.
#   - Logs go to ${TMPDIR:-/tmp}/trha-probes/ (not the repo).
set -u

cd "$(dirname "$0")/.." || exit 2
log_dir="${TMPDIR:-/tmp}/trha-probes"
mkdir -p "$log_dir"

pass=0
fail=0
skip=0
failed=()

is_heavy() {
  case "$1" in
    trha-cpu-braintoken|trha-cpu-real60|trha-cpu-b1lm) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  local name="$1" bin rc
  bin=$(cabal list-bin "exe:$name" 2>/dev/null) || {
    echo "SKIP  $name (not in build)"; skip=$((skip + 1)); return
  }
  [ -x "$bin" ] || { echo "SKIP  $name (no binary)"; skip=$((skip + 1)); return; }

  case "$name" in
    trha-webgpu-*)
      if [ ! -d /dev/dri ]; then
        echo "SKIP  $name (no /dev/dri)"; skip=$((skip + 1)); return
      fi
      ;;
  esac

  if is_heavy "$name" && [ "${PROBES_ALL:-0}" != "1" ]; then
    echo "SKIP  $name (heavy; set PROBES_ALL=1)"; skip=$((skip + 1)); return
  fi

  if timeout "${PROBE_TIMEOUT:-180}" "$bin" >"$log_dir/$name.log" 2>&1; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    rc=$?
    echo "FAIL  $name (exit $rc; log $log_dir/$name.log)"
    fail=$((fail + 1))
    failed+=("$name")
  fi
}

# Probe list mirrors `executable` stanzas in trha.cabal (excluding trha and
# trha-kernel-stub, which are services, not probes).
probes=(
  trha-webgpu-hello
  trha-webgpu-compute
  trha-webgpu-errorprobe
  trha-webgpu-gf27
  trha-webgpu-gf27matmul
  trha-webgpu-integprobe
  trha-webgpu-qprobe
  trha-webgpu-gpue2e
  trha-webgpu-layer60probe
  trha-webgpu-layerprobe
  trha-cpu-braintoken
  trha-cpu-gf27simd
  trha-cpu-bproto
  trha-cpu-realwuxing
  trha-cpu-b1
  trha-cpu-datagen
  trha-cpu-b1l
  trha-cpu-b1full
  trha-cpu-fltverdict
  trha-cpu-b1traj
  trha-cpu-b1lm
  trha-cpu-p1
  trha-cpu-layerprofile
  trha-cpu-real60
  trha-cpu-gf27matmul-probe
)

for p in "${probes[@]}"; do
  run "$p"
done

echo "SUMMARY pass=$pass fail=$fail skip=$skip (logs: $log_dir)"
if [ "$fail" -ne 0 ]; then
  printf 'FAILED: %s\n' "${failed[*]}"
  exit 1
fi
