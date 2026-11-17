# Worked example: exp, 8192x8192 fp32, 48 blocks

One complete collection, run 2026-11-17 on 910c-1 through the CANN 9.1.0 eval image. It is the
reference reading for `reference/03-analysis.md` and `reference/04-diagnosis.md`.

## Setup

- Kernel: `exp_kernel_f32` from `exp_kernel.cpp` (AscendC direct launch, double-buffered TQue,
  `DataCopyPad`, fp32 path: `Muls` then `Adds` then `Exp`).
- Harness: `exp_bench.cpp`, plain ACL host code. 67108864 elements, 10 launches, block count and tile
  from the kernel's own tiling helper.
- Build: `helpers/build_standalone.sh . exp_kernel.cpp exp_bench.cpp /work/exp_bench` (target
  `dav-2201`).
- Collection: `msprof op --application=/work/exp_bench --output=/work/prof2
  --aic-metrics=PipeUtilization --launch-count=1 --warm-up=3`.

Harness printout:

```
n=67108864 blocks=48 blocklen=1398102 tile=48832 reps=10 y[0]=1.000000
```

`tile` is bytes. 48832 B per buffer, four buffers (in/out x 2 pipeline stages) = 195 KB, which fills
the 192 KB UB.

## Facts

`OpBasicInfo.csv`: `exp_kernel_f32, vector, 347.306946 us, 48 blocks, freq 1800/1800`.

| metric | min | median | max |
|---|---|---|---|
| `aiv_time(us)` | 284.5 | 316.4 | 346.7 |
| `aiv_vec_time(us)` | 53.547 | 53.554 | 53.554 |
| `aiv_vec_ratio` | 0.154 | 0.170 | 0.188 |
| `aiv_mte2_time(us)` | 282.3 | 314.6 | 344.0 |
| `aiv_mte2_ratio` | 0.989 | 0.993 | 0.997 |
| `aiv_mte2_active_bw(GB/s)` | 15.16 | 16.68 | 18.47 |
| `aiv_mte3_time(us)` | 107.4 | 122.3 | 153.0 |
| `aiv_mte3_ratio` | 0.312 | 0.389 | 0.527 |

Traffic is fixed by the problem: 256 MiB read plus 256 MiB written, 536.9 MB in total.

```
aggregate_bw = 536.9 MB / 347.3 us = 1.55 TB/s
```

Cross-check against the benchmark that does not use a profiler: the same case in the cann-bench
evaluator reports about 352 us. Profiling here costs roughly 1.4%, so the replay is close to a clean
measurement.

## Diagnosis

**Primary: MTE2-bound (case A).** `aiv_mte2_ratio` is 0.989 or higher on all 48 blocks, while
`aiv_vec_ratio` sits at 0.15 to 0.19. The copy-in queue never idles; the vector pipe idles about 83%
of the time. The refuting check for case A fails to fire in one direction only: at 1.55 TB/s this is
close to a plausible HBM roof for one die, so there may be no scheduling headroom left. That roof has
not been measured on this machine, so it stays a hypothesis.

**Secondary: uneven blocks (case F).** `aiv_time` spans 284.5 to 346.7 us, a 1.22x spread, and the
kernel's duration is set by the slowest block. The work is *not* imbalanced: `aiv_vec_time` is
53.547 to 53.554 us on every block, and every block does 28 or 29 tiles of 12208 elements. So the
22% spread lives entirely in memory service, and `aiv_mte2_time` carries it (282 to 344 us).

Equalizing that spread is worth up to 1.22x on this shape, larger than any arithmetic change
available to `exp`. That is the number to test next, not the vector math.

## Recommendations, ranked

1. **Measure the read roof before tuning anything.** Write a copy-in-only kernel (load, discard) at
   the same block count and tile, and a plain copy kernel. If the read roof is near 1.5 TB/s, the
   current kernel is done and the remaining work is the spread. Prediction: `aiv_mte2_ratio` stays
   above 0.98 and `aiv_time` stays in the 280 to 350 us band. Falsified if a pure copy runs
   materially faster.
2. **Attack the block spread.** Same kernel, block count 24 and 96. If the spread comes from
   concurrent blocks contending for HBM channels, fewer blocks should narrow `aiv_time` toward the
   fast end while the total duration grows. Prediction: at 24 blocks the max-to-min `aiv_time` ratio
   drops below 1.10. Falsified if the spread is unchanged, which would point at a fixed per-block
   cost instead.
3. **Do not shrink the arithmetic.** The fp32 path already measures 0.17 vector utilization. Cutting
   vector instructions cannot move a kernel whose vector pipe idles 83% of the time.

## What was not collected

One `--aic-metrics` group: `PipeUtilization`. No cache (`L2Cache`), no memory-level
(`Memory`, `MemoryUB`, `MemoryL0`), no `ArithmeticUtilization`, no `Roofline`. A claim about L2 hit
rate or HBM clock cannot be made from this run.
