#!/usr/bin/env bash
# Collect one kernel with msopprof.
#
#   run_msprof_op.sh <application> <output_dir> [aic_metrics] [launch_count] [warm_up] [kernel_name]
#
# Keeps every collection argument in one place so two runs of the same kernel differ only where
# the caller meant them to differ.
#
# Environment:
#   SKIP_PREFLIGHT=1   collect even if npu_preflight.sh says the box is not ready
#   MAX_LOAD=<n>       load-average limit passed to the preflight (default 100)
set -euo pipefail

APP=${1:?application path}
OUT=${2:?output dir}
METRICS=${3:-PipeUtilization}
COUNT=${4:-1}
WARMUP=${5:-3}
KERNEL=${6:-}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CANN=${ASCEND_HOME_PATH:-/usr/local/Ascend/cann-9.1.0}
MSPROF="$CANN/tools/profiler/bin/msprof"
[[ -x "$MSPROF" ]] || MSPROF=$(command -v msprof) || { echo "no msprof found" >&2; exit 1; }

# A collection on a loaded box fails silently and its retries can wedge the die. Check first.
if [[ "${SKIP_PREFLIGHT:-0}" != "1" && -x "$HERE/npu_preflight.sh" ]]; then
    if ! "$HERE/npu_preflight.sh" --max-load "${MAX_LOAD:-100}"; then
        echo "preflight says this box is not ready; fix that or set SKIP_PREFLIGHT=1" >&2
        exit 1
    fi
fi

# msopprof refuses an output directory that any other user or group can write, and a default
# umask makes exactly that. Owner-only, before the binary is ever execed.
mkdir -p "$OUT"
chmod 700 "$OUT"

ARGS=(op --application="$APP" --output="$OUT" --aic-metrics="$METRICS"
      --launch-count="$COUNT" --warm-up="$WARMUP")
if [[ -n "$KERNEL" ]]; then
    echo "warning: --kernel-name is matched against an unmangled name. AscendC kernels appear in" >&2
    echo "         the dump mangled (_Z14gcd_kernel_i32PhS_S_lllllllllll), so the filter usually" >&2
    echo "         matches nothing and the collection comes back empty. Prefer a harness that" >&2
    echo "         launches only the kernel you want." >&2
    ARGS+=(--kernel-name="$KERNEL")
fi

echo "+ $MSPROF ${ARGS[*]}"
"$MSPROF" "${ARGS[@]}"

RUN=$(ls -d "$OUT"/OPPROF_* 2>/dev/null | sort | tail -1)
[[ -n "$RUN" ]] || { echo "no OPPROF_* directory produced" >&2; exit 1; }
if [[ ! -f "$RUN/OpBasicInfo.csv" || ! -f "$RUN/PipeUtilization.csv" ]]; then
    cat >&2 <<EOF
collection produced no CSV in $RUN.

msopprof prints "Op profiling finish" and leaves this directory either way, so an empty run is
not visible in its exit status. Two causes, in the order worth checking:

  1. Host contention. Collections fail this way whenever the box is loaded, and the failure is
     silent. Re-run ./npu_preflight.sh and wait for a quiet window.
  2. The profiled process itself crashed, exited non-zero, or launched no kernel. Run
     $APP by hand and check its exit status and output.

Do NOT wrap this in a retry loop. Retries leave msopprof processes holding GB of HBM and that is
what wedges a die. If you already retried, run ./npu_preflight.sh --reap now.
EOF
    exit 1
fi
echo "== $RUN"
cat "$RUN/OpBasicInfo.csv"
