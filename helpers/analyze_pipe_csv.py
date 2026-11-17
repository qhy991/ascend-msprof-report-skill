#!/usr/bin/env python3
"""Summarize an msopprof per-core CSV.

    analyze_pipe_csv.py <PipeUtilization.csv> [OpBasicInfo.csv]

Columns are read by name, never by position: CANN 8.5.0 and 9.1.0 emit the same metrics in a
different order, and a kernel the tool calls "mix" gets one row per sub_block (cube0, vector0,
vector1) per block. Rows are therefore grouped by sub_block_id and summarized per group.

The max/min spread is the part worth reading. Work imbalance shows up in the vector or cube time; a
spread in aiv_time with flat compute time is memory service, not work.
"""
import csv
import statistics
import sys
from collections import OrderedDict

IDENTITY = ("block_id", "sub_block_id")


def read_rows(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle))


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def metric_names(rows):
    seen = []
    for row in rows:
        for key in row:
            if key and key not in seen:
                seen.append(key)
    return [n for n in seen if n not in IDENTITY]


def summarize(rows, name):
    """min, median, max, and max/median.

    The spread is measured against the median, not the min: a mix-mode kernel emits a row per
    sub_block, and sub_blocks that received no work sit at a few tenths of a microsecond, which
    turns a max/min ratio into noise.
    """
    values = [v for v in (as_float(r.get(name)) for r in rows) if v is not None]
    if not values:
        return None
    low, high = min(values), max(values)
    mid = statistics.median(values)
    spread = (high / mid) if mid else None
    return low, mid, high, spread


def print_group(label, rows):
    print(f"\n-- sub_block {label}: {len(rows)} rows")
    print(f"{'metric':34} {'n':>3} {'min':>10} {'median':>10} {'max':>10} {'max/med':>8}")
    printed = 0
    for name in metric_names(rows):
        stats = summarize(rows, name)
        if stats is None:
            continue
        low, mid, high, spread = stats
        flag = ""
        if name in ("aiv_time(us)", "aic_time(us)") and spread and spread > 1.10:
            flag = "  <- uneven blocks"
        shown = f"{spread:8.2f}" if spread is not None else f"{'n/a':>8}"
        print(f"{name:34} {len(rows):3d} {low:10.3f} {mid:10.3f} {high:10.3f} {shown}{flag}")
        printed += 1
    if not printed:
        print("  (no numeric metrics)")


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    rows = read_rows(argv[1])
    if not rows:
        print("empty csv", file=sys.stderr)
        return 1

    if len(argv) > 2:
        for info in read_rows(argv[2]):
            op = info.get("Op Name") or info.get("Op Name ")
            if not op:
                continue
            print(f"op={op} type={info.get('Op Type')} "
                  f"duration_us={info.get('Task Duration(us)')} "
                  f"block_dim={info.get('Block Dim')} "
                  f"mix_block_dim={info.get('Mix Block Dim')}")

    groups = OrderedDict()
    for row in rows:
        groups.setdefault(row.get("sub_block_id") or "all", []).append(row)
    blocks = {row.get("block_id") for row in rows if row.get("block_id") is not None}
    print(f"blocks={len(blocks)} sub_blocks={list(groups)} rows={len(rows)}")

    for label, group_rows in groups.items():
        print_group(label, group_rows)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
