---
name: ascend-msprof-report-skill
description: Profile Ascend NPU kernels with msprof and msopprof on 910B/910C (AscendC, CANN 8.x/9.x), read the PipeUtilization counters, and produce an evidence-backed bottleneck report. Use for Ascend profiling, "为什么这个 kernel 在昇腾上慢", operator optimization campaigns, and any Ascend speed claim that needs a mechanism rather than a wall-clock number.
---

# Skill: Ascend Kernel Profiling (msprof / msopprof)

**When to use:** the user asks to profile a kernel on Ascend, explain why it is slow, decide what to
change next, or back an Ascend optimization claim with counters. Triggers include "profile X on
昇腾", "为什么这个 kernel 慢", "msprof 报告", "算子优化", "AI Core 利用率低".

**Target hardware (verified 2026-11-17):** Ascend 910C, device name `Ascend910_9382`
(8 cards x 2 dies = 16 dies, 64 GB HBM per die), compile short name `ascend910_93`,
Bisheng target `dav-2201`. Toolchain seen: CANN 9.1.0 in the official cann-bench eval image,
CANN 8.5.0 on the bare host. Both expose the same `msprof` CLI.

**Key mental model:** Ascend splits work into an AI Cube core (`aic_*` columns, matrix) and AI Vector
cores (`aiv_*` columns, elementwise). `msopprof` reports *pipe occupancy per core*, not a
normalized "% of peak". A ratio near 1.0 means "this pipe never idled", not "this pipe is fast".

---

## Golden rule

**Profile the kernel that ran. Report the counter that moved.**

`msprof op` replays a kernel launch, so it only sees work you actually launch from the profiled
process. A number from a different shape, a different block count, or a different dtype is not the
same measurement. Record the command, the CSV, and the launch parameters together.

---

## Environment facts (verified, do not re-derive)

- **Binary:** `/usr/local/Ascend/cann-<ver>/tools/profiler/bin/msprof`, and on `PATH` inside the
  official eval image. `msprof --version` is **not** a valid flag; use `msprof op -v`.
- **Two profilers, one CLI.** `msprof <app>` is the full trace (timeline, runtime API, task
  scheduling). `msprof op <args>` is `msopprof`, the kernel-level profiler with replay and hardware
  counters, and it is the one that answers "why is this kernel slow".
- **`msopprof` needs an executable, not a Python call.** `--application=<path>` execs a file. A shell
  wrapper works. There is also a `--config=<json>` op-config mode.
- **Output shape.** Every run writes `OPPROF_<timestamp>_<id>/` containing `OpBasicInfo.csv`,
  `PipeUtilization.csv` (name follows `--aic-metrics`), `dump/` binaries, and `visualize_data.bin`.
  Parse the CSVs; the dump is for MindStudio.
- **A vector-only kernel leaves every `aic_*` column `NA`.** That is normal, not a broken collection.
- **In the `OPS_MODE=none` cann-bench image, `torch_npu` cannot create a device tensor.** The builtin
  op package is stripped, so `torch.randn(..., device='npu')` dies inside `GEInitialize` with
  `FEOpsKernelInfoStore: Initialize custom and builtin sub-information library failed`. Profile a
  standalone ACL binary instead of a torch script; the `helpers/` build does exactly that.
- **Evaluating a submission and profiling it are different containers.** The harness container owns
  the score. Do not use profiling artifacts to claim a score, and do not re-run the harness to get
  counters.

---

## Quickstart

0. **Read this file, then `reference/01-environment.md`.** Pick the container that can see the NPU:
   `--privileged --ipc=host --device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc`
   plus `-v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro`. On a host whose dockerd runs
   without a bridge, add `--network=host` or the container never starts.
1. **Build a standalone harness** that launches the kernel N times. `helpers/build_standalone.sh`
   compiles an AscendC kernel (`.cpp` with `__global__ __aicore__`) together with a plain ACL host
   `main`. It takes the SoC target and include set from the submission's own CMake, so the binary
   matches what the evaluator builds.
2. **Check it runs and print the launch parameters** before profiling. Block count, block length,
   tile size, and dtype all belong in the report.
3. **Collect** with `helpers/run_msprof_op.sh` or by hand:
   `msprof op --application=./bench --output=./prof --aic-metrics=PipeUtilization --launch-count=1 --warm-up=3`.
   See `reference/02-collection.md` for the metric groups and the replay flags.
4. **Parse** with `helpers/analyze_pipe_csv.py`; never read 48 rows by eye.
5. **Diagnose** against `reference/04-diagnosis.md`. Name one primary bottleneck.
6. **Write** `profile/<run_name>/REPORT.md` from `reference/05-report-template.md`.

## Pages

- `reference/01-environment.md` — paths, versions, container flags, the torch/GE trap, compile flags
- `reference/02-collection.md` — `msprof op` flags, metric groups, output tree, what invalidates a run
- `reference/03-analysis.md` — the PipeUtilization column set, what each ratio means, aggregate math
- `reference/04-diagnosis.md` — playbook: MTE2-bound, MTE3-bound, vector-bound, scalar-wait, uneven blocks
- `reference/05-report-template.md` — the report shape and its rules
- `helpers/build_standalone.sh`, `helpers/run_msprof_op.sh`, `helpers/analyze_pipe_csv.py`
- `examples/exp-f32-8192/` — one complete verified run: kernel source, harness, CSVs, and the reading

## What this skill does not do

It does not measure wall-clock speedups. Use paired, no-profiler timing on the same device for a
speed claim. Profiling establishes *which pipe is the limit*; ordinary timing establishes *how much
you gained*.
