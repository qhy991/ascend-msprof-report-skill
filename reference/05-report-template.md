# Report template

One run is one directory:

```
profile/<run_name>/
├── harness/       kernel source, bench main, binary, build log
├── reports/       msprof command line (as run), OPPROF_*/ copied out of the container
├── analysis/      output of helpers/analyze_pipe_csv.py
└── REPORT.md
```

Name runs `<date>_<kernel>_<shape>_<variant>` so two hypotheses sort apart.

Write `REPORT.md` in that directory:

```markdown
# Profiling report: <kernel>, <shape>, <date>

## Question
What was asked, and the timing that motivated it.

## Setup
- Device: <device name>, <dies>, CANN <version>
- Build: kernel source path, bisheng target, block dim and tile from the harness output
- Collection: the exact msprof op command, --aic-metrics group, launch-count, warm-up
- Correctness: the kernel produced <value> for the reference input before profiling

## Facts
A small table of the counters that decided the diagnosis, each with its column name and the block
it came from. Include OpBasicInfo Task Duration and Block Dim. Include the aggregate bandwidth you
computed and the input bytes it came from.

## Diagnosis
One primary bottleneck, named by its playbook letter in reference/04-diagnosis.md. The counters that
support it and the counter you checked that could have refuted it. State the metrics you did not
collect.

## Recommendations
Ranked by expected impact. For each: what to change, which counter should move and roughly how far,
and what result would falsify the prediction.

## Next collection
The exact command for the follow-up run, ready to paste.
```

## Rules

1. Every claim cites a counter value and a row. "Bandwidth-bound" is not a finding; "`aiv_mte2_ratio`
   0.991 on block 0, 536.9 MB in 347.3 us = 1.55 TB/s over 48 blocks" is.
2. State unexamined dimensions. One `--aic-metrics` group per run means most of the machine is
   unmeasured in any single report.
3. One primary bottleneck.
4. No recommendation without a falsifiable prediction.
5. Keep the raw CSV next to the report. A summary without the table cannot be re-read.
