# ascend-msprof-report-skill

Profile Ascend NPU kernels with `msprof` and `msopprof` on 910B/910C, read the pipe counters, and
write a bottleneck report with a falsifiable next step.

This is the Ascend member of the per-vendor profiling skill family: `rocm-report-skill`,
`dcu-rocprof-report-skill`, `metax-report-skill`, `metal-profile-report-skill`.

## Install

Vendor the directory into a workspace the agent reads, or link it at user level:

```sh
ln -s "$PWD" ~/.claude/skills/ascend-msprof-report-skill
```

A flow that runs on the NPU should name the skill path in its first-round instructions rather than
relying on automatic triggering.

## Contents

- `SKILL.md` — when to use it, the golden rule, the verified environment, the quickstart
- `reference/01-environment.md` — paths, container flags, the stripped-image torch trap, build flags
- `reference/02-collection.md` — `msprof op` options, replay semantics, output tree
- `reference/03-analysis.md` — the full PipeUtilization column set and the aggregate arithmetic
- `reference/04-diagnosis.md` — the bottleneck playbook, each case with its confirming and refuting counter
- `reference/05-report-template.md` — report shape and rules
- `reference/06-shared-host.md` — collecting on a loaded 16-card node without wedging a die
- `helpers/build_standalone.sh` — Bisheng build of an AscendC kernel plus an ACL host harness
- `helpers/run_msprof_op.sh` — one collection, one command line
- `helpers/npu_preflight.sh` — gate on load, stale profilers and held HBM; `--reap` cleans up
- `helpers/analyze_pipe_csv.py` — per-block min/median/max and spread, no reading 48 rows by eye
- `examples/exp-f32-8192/` — a complete verified run with raw CSVs and the reading it produced

## Evidence

Every environment fact and column name here was checked on 2026-11-17 against a 910C node
(`Ascend910_9382`, 16 dies) with CANN 9.1.0 in the official cann-bench eval image.

**Replay durations are a relative signal, not a timing method.** In the bundled example the replay
landed within 1.4% of the evaluator (347.3 us against 352 us), but that agreement does not
generalise: on a 1M-element fp16 kernel the same comparison read 11.5 us under `msprof op` against
4.28 us in-harness, a factor of 2.7 (card-01 NOTES.md:3518). Use the replay to find which pipe is
the limit. Take every speed claim from paired, interleaved, no-profiler timing.

Claims about CANN 8.5.0, other SoCs, or other counter groups are not covered by that evidence.
Operational guidance for loaded multi-card hosts is in `reference/06-shared-host.md`, derived from a
16-card campaign on 2026-11-23/24.
