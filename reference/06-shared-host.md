# 06 — Collecting on a shared, loaded host

A 910C node carries 16 dies and, in an agent campaign, 16 independent workers. The collection
recipes in `02-collection.md` assume the profiler can get the machine for a few seconds. On a busy
box that assumption fails, it fails *silently*, and the obvious reaction to the silent failure is
what takes a die out.

Everything here was observed on a 910C campaign node, 2026-11-23/24.

## The silent failure

`msopprof` prints `Op profiling finish` and creates `OPPROF_<timestamp>_<id>/` whether or not it
collected anything. Under load it creates the directory with **no `PipeUtilization.csv`** inside.
The exit status does not distinguish the two cases.

> msprof worked once and then failed every subsequent time (`OPPROF_*` created with no
> `PipeUtilization.csv`) while the host load average sat at 110-235 — this box runs sixteen cards.
> — card-09 NOTES.md:6715

`02-collection.md` lists a crashed profiled process as the cause of an empty `OPPROF_*`. That is one
cause. **Host contention is the other, and on a shared box it is the common one.** Check the load
before you debug your binary.

The one collection that succeeded on that card was taken when the load was lower. The working rule:

- **Load average above ~100 on a 16-card node: do not collect.** Wait for a quiet window.
- Check with `helpers/npu_preflight.sh`, which gates on load, on your own stale profiler processes,
  and on per-die HBM. `run_msprof_op.sh` calls it automatically.

## The expensive reaction

The natural response to "the CSV is missing" is to retry. Do not loop it.

> While collecting the msprof counters I left `msopprof`/`c9_bench` processes running in the
> `c9bench` container (the collection kept producing an `OPPROF_*` directory with no
> `PipeUtilization.csv`, so my retry loops spawned more). Two of them sat in state `Rl` holding
> **11.3 GB of HBM each**, and the die went with them.
> — card-09 NOTES.md:6724

After that, a plain `torch_npu` tensor creation, the standalone harness, and a fresh harness run all
hung on that die.

### Recognising a wedged die

A harness that prints its banner and then produces **no output at all** for ten minutes, while
`npu-smi info` reports `AICore(%) 0` and a large, static HBM figure.

An idle 910C die sits near **2.9-3.2 GB** of HBM. The wedged one read `14440 / 65536`. The accuracy
stage of a healthy run takes about 30 s; 844 s with the device idle is a held die, not a slow one.

**HBM held with AICore at 0% is the signature.** A die that is merely busy shows AICore above zero.

### Clearing it, in order

1. `docker stop` the stuck eval container, if the collection ran inside one.
2. Kill the stale `msopprof` / `msprof` / harness processes **by pid**, inside the container that
   owns them.
3. Verify with `npu-smi info`. HBM went `14440 -> 3177 MB` and the next device call succeeded
   immediately.

**`pkill -f "msprof op"` does not reap them.** `msopprof` re-execs, and the survivor's argv is the
plain binary path, so the pattern you launched with no longer matches. Enumerate with
`pgrep -x msopprof` and kill by pid (match the executable name, not the command line).

**Verify with the HBM figure, not with the absence of the pattern.** The pattern disappears while
the memory is still held.

`helpers/npu_preflight.sh --reap` does steps 2 and 3 for processes owned by the current user.

## Only touch your own

On a shared node every other die belongs to someone else's work. The recovery above stayed inside
one card: the stale processes were all in that card's own container, and the stopped eval container
was that card's own. `npu_preflight.sh` filters on `-u $(id -u)` for the same reason. Never
`pkill` a profiler name globally on a box you share, and never `npu-smi reset` a card you do not
own — a reset that fails leaves `resetting (about 360 seconds)` and then `Failed to reset server`
(card-08 NOTES.md:4022).

## Measuring while the box is loaded

If you cannot get a quiet window, contention also moves the numbers you are trying to read:

- The `mte2` column on a loaded host swings about 6 us run to run, so a single paired comparison
  cannot resolve a small change (card-01 NOTES.md:7516).
- A host can sit in an elevated state for tens of minutes in which small cases read 20-50% high
  (card-13 NOTES.md:8743).

Both mean the same thing: on a shared box, profile for *mechanism* (which pipe is the limit) and
take speed claims from interleaved A/B timing, never from two runs separated in time.
