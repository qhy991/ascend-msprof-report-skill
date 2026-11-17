# Collection

Two profilers share one CLI. Pick by the question.

| Question | Tool | Command |
|---|---|---|
| Why is this kernel slow | `msopprof` (kernel-level, replay, counters) | `msprof op ...` |
| Where did the time go across many ops | `msprof` (trace) | `msprof [flags] <app>` |

## msopprof (`msprof op`)

Flags verified on CANN 9.1.0:

```
--application=<FILE>          executable to profile; a shell wrapper works
--output=<PATH>               default ./
--aic-metrics=<TYPE>          ArithmeticUtilization | MemoryUB | Memory | MemoryL0 | L2Cache |
                              PipeUtilization | ResourceConflictRatio | Default | BasicInfo | Roofline
--kernel-name=<NAME>          only this kernel; ignored in --config mode
--launch-count=<N>            1..5000, default 1
--launch-skip-before-match=<N> 0..1000, default 0
--replay-mode=<MODE>          application | kernel, default kernel
--warm-up=<N>                 0..500, default 5
--kill=<on|off>               stop the app once launch-count is reached
--mstx=<on|off>               include mstx ranges
--config=<FILE>               op-config JSON mode instead of an application
--custom-input=<FILE>         JSON inputs for op-config mode
```

A working command, used for the example run:

```bash
msprof op --application=/work/exp_bench \
          --output=/work/prof --aic-metrics=PipeUtilization \
          --launch-count=1 --warm-up=3
```

**Replay semantics matter.** `--replay-mode=kernel` (the default) re-executes the kernel with saved
and restored operator inputs, so side effects of earlier launches do not carry in. `application`
replays the whole application. `--warm-up` runs the kernel N times before the measured launch, which
is why a JIT or first-touch cost does not land in the counters.

**One metric group per run.** `--aic-metrics` selects a counter bank. Asking for everything in one
run is not supported; choose the group that answers the question, and run again for a second group.

## Output tree

```
<output>/OPPROF_<YYYYMMDDHHMMSS>_<16 char id>/
├── OpBasicInfo.csv          op name, type, task duration (us), block dim, device, freq
├── PipeUtilization.csv      one row per block (or per aiv sub-block); named after --aic-metrics
├── dump/                    DeviceProf*.bin, duration.bin, pc_start_addr.txt, L2Cache.bin
└── visualize_data.bin       MindStudio input
```

`OpBasicInfo.csv` is the header of the report: `Op Name, Op Type, Task Duration(us), Block Dim,
Mix Block Dim, Device Id, Pid, Current Freq, Rated Freq`. A `Task Duration` that disagrees wildly
with your own timing means you profiled a different launch, not that the profiler is wrong.

### The same kernel does not produce the same table on both releases

Measured on the identical binary, same shape, same block count:

| | CANN 9.1.0 (container) | CANN 8.5.0 (host) |
|---|---|---|
| `Op Type` | `vector` | `mix` |
| `Mix Block Dim` | `NA` | `96` |
| rows in `PipeUtilization.csv` | 48 | 144 |
| `sub_block_id` values | `vector0` | `cube0`, `vector0`, `vector1` |
| column order | `aic_scalar_*` after `aic_fixpipe_*` | `aic_scalar_*` before `aic_mte1_*` |

So `Op Type` is assigned by the release, not by the kernel's nature: this is a vector-only kernel
that 8.5.0 still splits into cube and vector sub-blocks. Never branch on `Op Type`, and never index
columns by position. Read columns by name and group rows by `sub_block_id`.

Rows equal `Block Dim` times the number of sub-blocks, so a 48-block mix kernel has 144 rows.
Counting rows and calling it the block count overstates the parallelism by 3x.

## The trace mode, for context

`msprof [flags] <app>` writes a `PROF_*` tree instead. Useful flags:

```
--task-time=l0|l1|l2|on|off     task scheduling granularity (default on)
--runtime-api                    host runtime API calls
--ascendcl                       ACL calls (default on)
--ge-api=l0|l1|off               GE events (default off)
--ai-core / --aic-mode=task-based|sample-based / --aic-freq=1..100
--aic-metrics=<group>            same groups as above
--mstx=on|off                    user ranges, with --mstx-domain-include/-exclude
--sys-hardware-mem=on            HBM/LLC counters, --sys-hardware-mem-freq
--sys-profiling / --sys-cpu-profiling / --sys-pid-profiling / --sys-io-profiling
--parse --export --analyze --query --clear     post-processing switches
--type=text|db                   output substrate
```

Use trace mode for gaps between kernels and host dispatch cost. Use `msopprof` for anything about
one kernel's internals. Do not infer per-pipe occupancy from a trace.

## What invalidates a run

- **A profiled process that crashed or exited non-zero.** `msopprof` still prints
  `Op profiling finish` and leaves an `OPPROF_*` directory with no CSVs. Check for the CSV before
  reading anything into the report.
- **A launch you did not intend.** `--launch-count=1` with no `--kernel-name` takes the first
  matching launch. If the harness runs several shapes, name the kernel or skip launches.
- **A different launch geometry than the claim.** 48 blocks and 96 blocks are different kernels for
  this purpose. Record `Block Dim` from `OpBasicInfo.csv`.
- **Mixed dtypes or attributes across launches.** An `exp` with `base=2` and an `exp` with natural
  base are different arithmetic on the same pipe; profile the one you are optimizing.
