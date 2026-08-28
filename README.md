# BABS scripts for the NIDM BIDS Apps

This repository runs three NIDM-emitting BIDS Apps — [FreeSurfer](https://github.com/ReproNim/freesurfer-nidm_bidsapp), [ANTs](https://github.com/ReproNim/ants-nidm_bidsapp), and [MRIQC](https://github.com/sensein/mriqc-nidm_bidsapp) — over a DataLad study dataset on a SLURM cluster, using [BABS](https://github.com/PennLINC/babs) to manage one job per subject.

Each app has a thin wrapper script; everything they share lives in `babs_common.sh`. A wrapper takes a site through the whole launch sequence in one command: it finds the container image, builds a DataLad container dataset, fills in the app's YAML config, runs `babs init`, and submits one SLURM job per subject. You then wait for the jobs, resubmit any preemption casualties, and harvest the results with the study's own post-processing script.

```bash
./freesurfer-nidm_babs_script.sh Caltech study-ABIDE
```

This exact pipeline produced the 38-subject Caltech FreeSurfer derivative in `study-ABIDE/site-Caltech/derivatives/babs-freesurfer-nidm`, so every step below is validated end to end.

## How the pieces fit together

The scripts expect a study dataset laid out the way the SIMPLE2 DataLad tree is:

```
<DATALAD_SET_DIR>/<study>/site-<SITE>/
├── sourcedata/raw          # the BIDS input dataset
├── derivatives/nidm_4.5.0  # existing per-subject NIDM records the apps augment
├── derivatives/babs-<app>_<date>   # <- a run creates this (the BABS project)
└── code/post_babs.sh       # the study's harvest script (see Post-processing)
```

Three kinds of storage are involved, and they are deliberately separate:

- **The study tree** (`DATALAD_SET_DIR`) holds the inputs and receives the finished BABS project. This is the durable, shared location.
- **Scratch** (`SCRATCH_DIR_*`) holds each run's working copy of the config, the container DataLad dataset, and the run log. Disposable after harvest.
- **Compute space** (`SCRATCH_DIR_COMPUTE`) is where the individual SLURM jobs clone, run, and zip their results. BABS cleans up after successful jobs.

## Prerequisites (one-time setup)

### 1. BABS — must be installed from git main, not PyPI

The configs here use the configurable BIDS-study layout from [PennLINC/babs PR #369](https://github.com/PennLINC/babs/pull/369) (`analysis_path: "."`, inputs under `sourcedata/`, RIA stores under `.babs/`). That layout is not in any PyPI release yet, and the failure mode on the released 0.5.2 is nasty: the three layout keys are **silently ignored**, `babs init` succeeds, and you get a legacy-layout project with no error — which the harvest script then can't process.

```bash
micromamba create -n babs-369 -f environment_hpc.yml -y
micromamba activate babs-369
pip install git+https://github.com/PennLINC/babs.git
```

(`environment_hpc.yml` ships in this repo; it is BABS's own HPC environment file.) The wrappers activate the `babs-369` env by name — set `BABS_ENV` if you called yours something else — and refuse to run if the active babs predates 0.5.5.

### 2. Cluster software

Apptainer (or Singularity) for running the containers, and `git-annex` — the wrappers load the `apptainer` module themselves; git-annex comes with the micromamba env. DataLad is installed by `environment_hpc.yml`.

### 3. The container image

Each wrapper looks for its `.sif` file (e.g. `freesurfer-nidm_bidsapp.sif`) in this repo's directory first, then in a short list of fallback paths. Build the image from the matching app repository (each has a `Singularity` recipe and a `setup.py` helper) and drop it next to the scripts. The expected filenames are set at the top of each wrapper script.

### 4. A `.env` file

The wrappers source `.env` from the **current working directory**, so always run them from this repo's root. A complete, real example:

```bash
BASE_DIR='/home/me/simple2_bidsapp_babs'
SCRATCH_DIR_FS='/scratch/me/simple2/fs_bidsapp_babs'
SCRATCH_DIR_ANTS='/scratch/me/simple2/ants_bidsapp_babs'
SCRATCH_DIR_MRIQC='/scratch/me/simple2/mriqc_bidsapp_babs'
SCRATCH_DIR_COMPUTE='/scratch/me/'
DATALAD_SET_DIR='/data/lab/datasets/simple2_datalad'
FS_LICENSE='/home/me/license.txt'          # FreeSurfer runs only
```

This is plain bash — quote the values, no spaces around `=`.

### 5. FreeSurfer license (FreeSurfer runs only)

Get a free license from [the FreeSurfer site](https://surfer.nmr.mgh.harvard.edu/registration.html) and point `FS_LICENSE` at it. The wrapper fails fast at launch — not two hours later inside every job — if the variable is unset or the file is missing.

### 6. Git access to datasets you don't own

Shared study trees are routinely operated on by people other than their owner, and git refuses that by default ("dubious ownership"). Allow the paths you'll work with:

```bash
git config --global --add safe.directory '<DATALAD_SET_DIR>/<study>/site-<SITE>'
git config --global --add safe.directory '<DATALAD_SET_DIR>/<study>/site-<SITE>/sourcedata/raw'
```

The harvest script checks this up front and prints the exact command when it's missing.

## Running

```bash
# subject-level (the default)
./freesurfer-nidm_babs_script.sh Caltech study-ABIDE
./ants-nidm_babs_script.sh Caltech study-ABIDE
./mriqc-nidm_babs_script.sh Caltech study-ABIDE

# session-level, for multi-session datasets
./freesurfer-nidm_babs_script.sh Brown study-ADHD200 session
```

Every run is stamped with `RUN_DATE` (auto-generated as `YYMMDD`, e.g. `260827`). The stamp names the scratch run directory, the compute space, the log file, and — by default — the project itself:

- **BABS project** (the deliverable): `<DATALAD_SET_DIR>/<study>/site-<SITE>/derivatives/babs-<app>_<RUN_DATE>`
- **Scratch run dir**: `<SCRATCH_DIR_app>/<study>_<RUN_DATE>/` — config copy, container dataset
- **Log**: `<SCRATCH_DIR_app>/babs_script_<RUN_DATE>_<timestamp>.log` — everything the run printed, survives your terminal

### Knobs

All optional, all environment variables:

| Variable | What it does |
|---|---|
| `RUN_DATE=260827` | Pin the date stamp instead of auto-generating it. |
| `BABS_OUTPUT_DIR=/path` | Put the project at a fixed, undated path (e.g. the canonical `derivatives/babs-freesurfer-nidm` a site publishes). Wins over the dated default; the scratch/log/job names keep their date stamp. Must be decided before `babs init` — babs bakes absolute paths into the project, so it cannot be renamed afterwards. |
| `BABS_SKIP_CHECK_SETUP=1` | **Currently required for every run.** `babs check-setup` crashes on the PR #369 study layout (it hardcodes a `inputs/data` path that no longer exists). The wrapper prints a reminder when it skips. |
| `BABS_SUBMIT_COUNT=N` | Submit only the first N jobs — a controlled ramp for when an app's memory/time needs are unverified. Measure the first completions, adjust the config, then `babs submit` the rest into the same project. |
| `BABS_LIST_SUB_FILE=/path.csv` | Restrict the project to the subjects in a CSV (single `sub_id` column). For pilots and re-runs. |
| `BABS_ENV=name` | Micromamba env holding babs (default `babs-369`). |
| `BABS_NIDM_DERIV=name` | Which NIDM derivative under `derivatives/` to augment (default `nidm_4.5.0`). |

## While the jobs run

Check on things from the project directory:

```bash
micromamba activate babs-369
cd <DATALAD_SET_DIR>/<study>/site-<SITE>/derivatives/babs-<app>_<date>
babs status
```

Two SLURM realities to know about:

**Preemption is expected.** The configs use `mit_preemptable` (591 nodes, 2-day ceiling) rather than `mit_normal` (50 nodes, 12 h) — more throughput, occasional casualties. Every config also sets `#SBATCH --no-requeue`, and must: the partition requeues preempted jobs under the *same* SLURM id, the job then recomputes the same branch name, and its `mkdir` fails. `--no-requeue` turns preemption into a clean failure that can simply be resubmitted. (Of the 38 Caltech FreeSurfer jobs, 4 were preempted; all completed on resubmission.)

**Resubmission only works after the queue drains.** `babs submit` refuses to run — "There are still jobs running" — while *any* of the project's jobs are pending or running. So when a preemption notice arrives mid-run, there is nothing to do yet. Wait for the whole array to finish, then run one batch round:

```bash
babs status     # refreshes the job table, marks the failures
babs submit     # resubmits exactly the subjects without results
```

Repeat if the resubmitted round itself loses jobs to preemption.

## After the jobs finish: post-processing

**The harvest script lives in the dataset, not in this repo** — `<DATALAD_SET_DIR>/<study>/site-<SITE>/code/post_babs.sh` — and that's deliberate: it's per-site, it's owned by the data manager, and two divergent copies of it is how a study ends up half-harvested.

```bash
micromamba activate babs-369
<site>/code/post_babs.sh <site>/derivatives/babs-<app>_<date>
```

It merges the per-job result branches, syncs the local checkout with the output RIA, fetches and unzips the result zips (one `sub-<id>/` per subject), drops the now-redundant zip content, and commits the site dataset's updated submodule pointer. It is safe to re-run: an interrupted harvest resumes, and an already-harvested project is detected rather than re-fetched.

Failure modes it already handles — the reason not to reimplement it:

- **`git-annex` must be on PATH.** These datasets set `filter.annex.process`, so any checkout or rebase shells out to git-annex; without it, git quietly empties tracked files mid-operation.
- **`babs merge` is not idempotent.** It deletes the `job-*` branches from the output RIA once merged, so a second invocation claims no job ever finished. The script counts the RIA's remaining job branches instead of believing that message.
- **Local and RIA histories diverge routinely** (saving `code/` after submission). The script fast-forwards when possible and auto-replays local commits only when they're confined to `code/`, leaving a timestamped backup ref either way.
- **Incremental harvests work.** Already-extracted subjects are detected by directory, so a re-run after a second batch of jobs extracts only the new subjects instead of re-fetching tens of GB.

### Merging the per-subject NIDM TTLs

Also the dataset's job, for the same anti-divergence reason. Any implementation has to satisfy two constraints, both measured against a real harvested project:

1. **Match the per-subject layout.** The apps write `sub-<id>[/ses-<x>]/nidm.ttl` directly. A glob expecting an intermediate directory (e.g. `sub-*/nidm_output/nidm.ttl`) finds zero files and writes a near-empty merge without erroring.
2. **Exclude the non-result subtrees.** A bare recursive search for `nidm.ttl` also sweeps in `sourcedata/NIDM/` (the *input* records the apps appended to) and any leftover `merge_ds/`, silently doubling graphs. Skip `sourcedata`, `merge_ds`, `.babs`, `.git`, `.datalad`, `containers`, `code`, `inputs`.

A known-good implementation is preserved in this repo's history: `git show 342b960:merge_ttl_files.py`.

## Per-app configuration

Each app's YAML config sets its SLURM resources, verified against real runs:

| Config | Resources | Notes |
|---|---|---|
| `config_freesurfer-nidm.yaml` | 8 CPUs, 24 GB, 3.5 h | needs `FS_LICENSE`; jobs measured ~2–3 h, ~29 GB peak |
| `config_ants-nidm.yaml` | 8 CPUs, 32 GB, 18 h | joint label fusion dominates the time |
| `config_mriqc-nidm.yaml` | 12 CPUs, 18 GB, 25 min | |

The wrappers substitute the environment-specific values (paths, license, session flag) into a copy of the config at launch; the copy lands in the scratch run directory so every run records exactly what it used.

## Adding a new BIDS App

1. Create `config_<app>-nidm.yaml` (start from an existing one).
2. Create `<app>-nidm_babs_script.sh` from an existing wrapper — the app-specific part is just the block of variables at the top: `APP_NAME`, `SCRATCH_DIR`, `CONTAINER_DS_NAME`, `CONTAINER_NAME`, `SIF_FILENAME`, `SIF_ALT_PATHS`.
3. Add the matching `SCRATCH_DIR_<APP>` to `.env`.

Everything else — argument parsing, container dataset setup, config substitution, init, submit — comes from `babs_common.sh`.
