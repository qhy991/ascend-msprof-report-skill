# Diagnosis playbook

Match the counter pattern to a case, then check the refuting counter before committing. If two cases
fit, rank them and name only the top one as the primary bottleneck.

## A. MTE2-bound (copy-in is the limit)

**Pattern:** `aiv_mte2_ratio` above ~0.9 while `aiv_vec_ratio` stays well under it.
**Refute:** if the block's bytes divided by `aiv_time` already sits near measured HBM read peak, the
copy is at hardware limit and no scheduling change will help. You are done optimizing this loop.
**Then:** reduce bytes (dtype, fusion, skip a redundant load), raise reuse per load (larger tile so
each element is used more times), or raise occupancy so more cores pull concurrently. Check the
stride pattern before anything else: a strided or unaligned `DataCopyPad` issues many small transfers
and shows the same signature.

## B. MTE3-bound (copy-out is the limit)

**Pattern:** `aiv_mte3_ratio` dominant, `aiv_mte2_ratio` lower, `aiv_mte3_active_bw` far from peak.
**Refute:** a kernel that writes 8x what it reads is legitimately write-bound; the fix is fewer output
bytes, not a smarter store.
**Then:** write less (fuse the next consumer, quantize output), or fix alignment so each store is one
burst.

## C. Vector-bound (compute is the limit)

**Pattern:** `aiv_vec_ratio` high and the vector time accounts for most of `aiv_time`, with MTE ratios
below it.
**Then:** count the vector instructions per element. `Exp`/`Tanh` cost more than they look. An fp16 or
bf16 path that casts to fp32, computes, and casts back spends two extra ops per element; check whether
the native half-precision intrinsic exists before accepting the cast. If the math cannot shrink, split
the work across more blocks.

## D. Cube-side cases (matmul kernels)

Read the `aic_*` columns instead.

- **`aic_cube_ratio` low, `aic_mte1_ratio` high** means L1 is starving the cube. Tiling is too small,
  or the NZ layout conversion is happening inside the loop. Larger K tiles, or pre-convert the layout.
- **`aic_cube_ratio` low, `aic_fixpipe_ratio` high** means the accumulator drain dominates. Reduce
  output frequency, or split so each core drains less.
- **`aic_cube_ratio` low and nothing else high** means the core is waiting. Look at
  `aic_scalar_wait_time` and the block spread; this is usually a dependency or a tail effect, not a
  pipe.

## E. Scalar-bound

**Pattern:** `aiv_scalar_ratio` high while `aiv_scalar_vector_stall_time` and
`aiv_scalar_mte2_stall_time` stay low.
**Then:** the per-element address arithmetic is the cost. Hoist index math out of the loop and use one
`DataCopyPad` with a computed element count instead of per-element addressing.

## F. Uneven blocks

**Pattern:** `aiv_time` across blocks has a spread much larger than the work imbalance predicted by
tiles-per-block.
**Refute:** compute tiles per block from the tiling parameters. If the fastest and slowest block differ
by one tile, a 20% spread is not imbalance.
**Then:** it is memory service. Blocks that start at the same time contend for the same HBM channels.
Try a different block-to-address mapping, or oversubscribe the cores so the tail is amortized. Do not
report this as a cause from the counters alone; the CSV shows the symptom, not the channel mapping.

## G. Nothing is saturated

**Pattern:** every ratio stays under ~0.5 and `Task Duration` is far larger than `aiv_time`.
**Then:** the kernel is not the cost. Use trace mode (`msprof <app>` with `--task-time`) to look at
gaps, host dispatch, and synchronization. A short kernel repeated many times is a launch problem, not
an AI Core problem.

## State of evidence

Cases A and F were exercised on hardware: the example run in `examples/exp-f32-8192/` is an
MTE2-bound kernel with uneven blocks, measured on both CANN 9.1.0 and CANN 8.5.0. Cases B, C, D, E
and G are read off the documented meaning of the columns and have not been confirmed against a
kernel that actually exhibits them. Treat their counter patterns as hypotheses to check, and say so
in the report.

## Rules

1. One primary bottleneck per report. Others are ranked follow-ups.
2. Every claim names the counter, its value, and the row it came from.
3. State what you did not collect. `--aic-metrics` selects one group, so a PipeUtilization-only run
   cannot speak to cache behavior.
4. A recommendation must name the counter that will move if it works. That is what makes the next run
   a test rather than a retry.
