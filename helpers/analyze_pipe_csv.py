#!/usr/bin/env python3
"""Summarize an msopprof per-core CSV across blocks.

    analyze_pipe_csv.py <PipeUtilization.csv> [OpBasicInfo.csv]

Prints, per metric column, the count, min, median and max over blocks, plus the max/min spread.
A spread far above the work imbalance is the signal that blocks are not seeing equal service.
"""
import csv
import statistics
import sys


def read_rows(path):
    with open(path, newline="") as handle:
        return [row for row in csv.DictReader(handle)]


def as_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def columns(rows):
    seen = []
    for row in rows:
        for key in row:
            if key and key not in seen:
                seen.append(key)
    return seen


def summarize(rows, name):
    values = [v for v in (as_float(r.get(name)) for r in rows) if v is not None]
    if not values:
        return None
    low, high = min(values), max(values)
    spread = (high / low) if low else float("inf")
    return len(values), low, statistics.median(values), high, spread


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
                  f"block_dim={info.get('Block Dim')}")

    print(f"blocks={len(rows)}")
    print(f"{'metric':34} {'n':>3} {'min':>10} {'median':>10} {'max':>10} {'max/min':>8}")
    for name in columns(rows):
        if name in ("block_id", "sub_block_id"):
            continue
        stats = summarize(rows, name)
        if stats is None:
            continue
        n, low, mid, high, spread = stats
        flag = ""
        if name in ("aiv_time(us)", "aic_time(us)") and spread > 1.10:
            flag = "  <- uneven blocks"
        print(f"{name:34} {n:3d} {low:10.3f} {mid:10.3f} {high:10.3f} {spread:8.2f}{flag}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
