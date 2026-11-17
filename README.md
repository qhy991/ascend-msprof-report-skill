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
- `helpers/build_standalone.sh` — Bisheng build of an AscendC kernel plus an ACL host harness
- `helpers/run_msprof_op.sh` — one collection, one command line
- `helpers/analyze_pipe_csv.py` — per-block min/median/max and spread, no reading 48 rows by eye
- `examples/exp-f32-8192/` — a complete verified run with raw CSVs and the reading it produced

## Evidence

Every environment fact and column name here was checked on 2026-11-17 against a 910C node
(`Ascend910_9382`, 16 dies) with CANN 9.1.0 in the official cann-bench eval image. The example run
produced a 347.3 us task duration against a 352 us evaluator measurement for the same case, so the
replay agrees with ordinary timing to about 1.4%.

Claims about CANN 8.5.0, other SoCs, or other counter groups are not covered by that evidence.
