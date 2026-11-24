#!/usr/bin/env bash
# Decide whether this box can be profiled right now, and clean up after a collection that died.
#
#   npu_preflight.sh [--device N] [--max-load N] [--reap] [--quiet]
#
# Why this exists: on a shared multi-card host, `msopprof` collections fail silently under load
# (an OPPROF_* directory appears with no CSV), and a retry loop around that failure leaves stale
# profiler processes holding GB of HBM until the die stops answering. See reference/06-shared-host.md.
#
# Exit 0 = ready to profile. Exit 1 = do not profile yet. Exit 2 = usage/environment error.
set -uo pipefail

DEVICE=""
MAX_LOAD=100          # card-09: every collection above ~100 failed; the one that worked was lower
HBM_IDLE_MB=4096      # an idle 910C die sits near 2.9-3.2 GB; above this something holds memory
REAP=0
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)   DEVICE=${2:?--device needs a value}; shift 2 ;;
        --max-load) MAX_LOAD=${2:?--max-load needs a value}; shift 2 ;;
        --reap)     REAP=1; shift ;;
        --quiet)    QUIET=1; shift ;;
        -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
        *)          echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

say() { [[ $QUIET -eq 1 ]] || echo "$@"; }
ready=0   # set to 1 by any blocking condition

# ---------------------------------------------------------------- 1. host load
load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || uptime | sed 's/.*load average: //' | cut -d, -f1)
if awk -v l="$load1" -v m="$MAX_LOAD" 'BEGIN{exit !(l+0 > m+0)}'; then
    say "BLOCKED  load average ${load1} is above ${MAX_LOAD}."
    say "         msopprof collections fail silently at this load: an OPPROF_* directory appears"
    say "         with no PipeUtilization.csv. Wait for a quiet window instead of retrying."
    ready=1
else
    say "ok       load average ${load1} (limit ${MAX_LOAD})"
fi

# ------------------------------------------------- 2. stale profilers owned by me
# `pkill -f "msprof op"` does NOT reap these: msopprof re-execs and the survivor's argv is the
# plain binary path. Match the binary name, and kill by pid.
find_stale() {
    local pid out=()
    for pid in $(pgrep -u "$(id -u)" -f 'msopprof|msprof' 2>/dev/null); do
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        out+=("$pid")
    done
    printf '%s\n' "${out[@]:-}"
}

mapfile -t stale < <(find_stale)
stale=($(printf '%s\n' "${stale[@]:-}" | grep -E '^[0-9]+$' || true))
if [[ ${#stale[@]} -gt 0 ]]; then
    say "FOUND    ${#stale[@]} profiler process(es) of your own still running:"
    ps -o pid=,etime=,rss=,args= -p "$(IFS=,; echo "${stale[*]}")" 2>/dev/null | cut -c1-140 | sed 's/^/         /'
    if [[ $REAP -eq 1 ]]; then
        say "         reaping by pid (SIGTERM, then SIGKILL after 5s)"
        kill "${stale[@]}" 2>/dev/null || true
        for _ in 1 2 3 4 5; do
            sleep 1
            [[ -z "$(find_stale | grep -E '^[0-9]+$' || true)" ]] && break
        done
        [[ -n "$(find_stale | grep -E '^[0-9]+$' || true)" ]] && kill -9 "${stale[@]}" 2>/dev/null
        say "         reaped. Confirm with the HBM figure below, not with the absence of the pattern."
    else
        say "         re-run with --reap to kill them by pid (only your own are touched)."
        ready=1
    fi
else
    say "ok       no profiler processes of your own are running"
fi

# ------------------------------------------------------------------- 3. HBM held
if command -v npu-smi >/dev/null 2>&1; then
    # chip rows look like: | 0     0        | 0000:9D:00.0  | 0    0 / 0    3142 / 65536  |
    # Columns are pipe-separated: col2 "<Chip> <Phy-ID>", col4 "<AICore%> <Mem used>/<tot> <HBM used>/<tot>".
    held=$(npu-smi info 2>/dev/null | awk -v want="$DEVICE" '
        /^\| [0-9]+ +[0-9]+ +\| [0-9a-fA-F]{4}:/ {
            split($0, col, /\|/)
            split(col[2], c, /[ \t]+/); phy = c[3]
            n = split(col[4], g, /[ \t]+/); aicore = g[2]; hbm = ""
            for (i = n; i > 1; i--) if (g[i] == "/") { hbm = g[i-1]; break }
            if (hbm != "" && (want == "" || phy == want)) printf "%s %s %s\n", phy, hbm, aicore
        }')
    if [[ -n "$held" ]]; then
        while read -r phy mb aicore; do
            [[ -z "${mb:-}" ]] && continue
            if (( mb > HBM_IDLE_MB )); then
                say "BUSY     device ${phy} holds ${mb} MB of HBM, AICore ${aicore}% (idle is ~3000 MB)"
                [[ "${aicore:-0}" == "0" ]] && \
                say "         HBM held with AICore 0% is the wedged-die signature, not a slow run;"
                say "         see reference/06-shared-host.md for the recovery order."
                ready=1
            else
                say "ok       device ${phy} HBM ${mb} MB, AICore ${aicore}%"
            fi
        done <<< "$held"
    else
        say "warn     npu-smi produced no chip rows; HBM not checked"
    fi
else
    say "warn     npu-smi not on PATH (normal inside a container); HBM not checked"
fi

if [[ $ready -eq 0 ]]; then
    say "READY    collect now"
    exit 0
fi
say "NOT READY"
exit 1
