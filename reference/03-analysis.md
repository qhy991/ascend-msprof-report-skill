# Analysis: reading the PipeUtilization CSV

`PipeUtilization.csv` has one row per block and per sub-block. On a vector-only kernel the `aic_*`
half is `NA` and the `aiv_*` half carries everything.

## Column set (verified)

Left side, per block:

```
block_id, sub_block_id
aic_time(us), aic_total_cycles, aic_cube_time(us), aic_cube_ratio,
aic_mte1_time(us), aic_mte1_ratio, aic_mte2_time(us), aic_mte2_ratio,
aic_mte3_time(us), aic_mte3_ratio, aic_mte3_active_bw(GB/s),
aic_fixpipe_time(us), aic_fixpipe_ratio, aic_fixpipe_active_bw(GB/s),
aic_icache_miss_rate, aic_scalar_time(us), aic_scalar_ratio,
aic_scalar_single_time(us), aic_scalar_dual_time(us),
aic_scalar_mte1_stall_time(us), aic_scalar_mte2_stall_time(us),
aic_scalar_mte3_stall_time(us), aic_scalar_cube_stall_time(us),
aic_scalar_wait_ib_time(us), aic_scalar_wait_time(us)
```

Right side, per block:

```
aiv_time(us), aiv_total_cycles, aiv_vec_time(us), aiv_vec_ratio,
aiv_mte2_time(us), aiv_mte2_ratio, aiv_mte2_active_bw(GB/s),
aiv_mte3_time(us), aiv_mte3_ratio, aiv_mte3_active_bw(GB/s),
aiv_icache_miss_rate, aiv_scalar_time(us), aiv_scalar_ratio,
aiv_scalar_single_time(us), aiv_scalar_dual_time(us),
aiv_scalar_mte2_stall_time(us), aiv_scalar_mte3_stall_time(us),
aiv_scalar_stall_by_ub_time(us), aiv_scalar_vector_stall_time(us),
aiv_scalar_wait_ib_time(us), aiv_scalar_wait_time(us)
```

## What the numbers mean

- **`aiv_time`** is that block's own wall time, not the kernel's. The kernel's `Task Duration` in
  `OpBasicInfo.csv` is set by the slowest block plus launch overhead.
- **`*_ratio`** is `pipe_time / aiv_time` for that block. `0.99` means the pipe was busy for 99% of
  the block's life. It says nothing about whether that time was well spent.
- **`*_active_bw`** is bandwidth *during the pipe's active intervals*, not averaged over the block.
  Never sum it across blocks to get device bandwidth, it double counts overlapped intervals. Compute
  aggregate bandwidth from bytes and `Task Duration`.
- **`aiv_scalar_vector_stall_time`** near `aiv_time` means the scalar unit spent the block waiting on
  the vector queue. That is normal for a queue-fed kernel, not a finding.
- **`aiv_icache_miss_rate`** above a few percent points at instruction footprint, usually an
  over-unrolled inner loop, not data traffic.

## The arithmetic that belongs in the report

```
traffic_bytes = read_bytes + written_bytes          # from the harness, not from the profiler
aggregate_bw  = traffic_bytes / Task Duration
per_block_bw  = traffic_bytes / block_dim / aiv_time
```

Both numbers are worth stating. The kernel-level one says how close to HBM you are. The per-block one
says whether an individual core was starved.

## Reading the distribution, not the average

Rows differ. Two blocks in the same kernel can be 20% apart, and the kernel duration follows the
slowest. `helpers/analyze_pipe_csv.py` prints min, median, max, and the spread for each ratio so a
bimodal kernel is visible immediately.

A spread much larger than the work imbalance (compare tiles per block from the tiling parameters)
means the blocks are not seeing equal memory service. That is a real finding, and it is invisible in
a single averaged line.

## Worked example

`examples/exp-f32-8192/` is one complete run: `exp_kernel_f32`, 8192x8192 fp32, 48 blocks,
tile 48832 elements. The reading and the report it produced are in that directory's `README.md`.
