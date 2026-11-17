#!/usr/bin/env bash
# Collect one kernel with msopprof.
#
#   run_msprof_op.sh <application> <output_dir> [aic_metrics] [launch_count] [warm_up] [kernel_name]
#
# Keeps every collection argument in one place so two runs of the same kernel differ only where
# the caller meant them to differ.
set -euo pipefail

APP=${1:?application path}
OUT=${2:?output dir}
METRICS=${3:-PipeUtilization}
COUNT=${4:-1}
WARMUP=${5:-3}
KERNEL=${6:-}

CANN=${ASCEND_HOME_PATH:-/usr/local/Ascend/cann-9.1.0}
MSPROF="$CANN/tools/profiler/bin/msprof"
[[ -x "$MSPROF" ]] || MSPROF=$(command -v msprof) || { echo "no msprof found" >&2; exit 1; }

mkdir -p "$OUT"
ARGS=(op --application="$APP" --output="$OUT" --aic-metrics="$METRICS"
      --launch-count="$COUNT" --warm-up="$WARMUP")
[[ -n "$KERNEL" ]] && ARGS+=(--kernel-name="$KERNEL")

echo "+ $MSPROF ${ARGS[*]}"
"$MSPROF" "${ARGS[@]}"

RUN=$(ls -d "$OUT"/OPPROF_* 2>/dev/null | sort | tail -1)
[[ -n "$RUN" ]] || { echo "no OPPROF_* directory produced" >&2; exit 1; }
if [[ ! -f "$RUN/OpBasicInfo.csv" || ! -f "$RUN/PipeUtilization.csv" ]]; then
    echo "collection produced no CSV in $RUN; the profiled process failed" >&2
    exit 1
fi
echo "== $RUN"
cat "$RUN/OpBasicInfo.csv"
