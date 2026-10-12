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
├── derivatives/babs-<app>  # <- a run creates this (the BABS project)
└── code/post_babs.sh       # the study's harvest script (see Post-processing)
```

Three kinds of storage are involved, and they are deliberately separate:

- **The study tree** (`DATALAD_SET_DIR`) holds the inputs and receives the finished BABS project. This is the durable, shared location.
- **Scratch** (`SCRATCH_DIR_*`) holds each run's working copy of the config, the container DataLad dataset, and the run log. Disposable after harvest.
- **Compute space** (`SCRATCH_DIR_COMPUTE`) is where the individual SLURM jobs clone, run, and zip their results. BABS cleans up after successful jobs.

## Prerequisites (one-time setup)

### 1. BABS — must be installed from git main, not PyPI

The configs here use the configurable BIDS-study layout from [PennLINC/babs PR #369](https://github.com/PennLINC/babs/pull/369) (`analysis_path: "."`, inputs under `sourcedata/`, RIA stores under `.babs/`). That PR is merged upstream, but the latest release (0.5.4) predates it — and the failure mode on any released babs is nasty: the three layout keys are **silently ignored**, `babs init` succeeds, and you get a legacy-layout project with no error, which the harvest script then can't process.

```bash
micromamba create -n babs -f environment_hpc.yml -y
micromamba activate babs
pip install "babs @ git+https://github.com/PennLINC/babs.git@ea5d6f0"
babs --version    # expect: babs v0.5.5.dev32+gea5d6f023
```

There is no 0.5.5 release, tag or branch to look for. babs derives its version from git tags, so an install from `main` reports the next release as a dev version, `0.5.5.devN+g<sha>`. `ea5d6f0` is the commit these scripts were last run against; later `main` should also work but is untested here.

(`environment_hpc.yml` ships in this repo; it is BABS's own HPC environment file.) The wrappers activate the `babs` env by name — set `BABS_ENV` in `.env` if you called yours something else — and refuse to run if the active babs predates 0.5.5, so a stale env fails loudly rather than building a broken project. Do not bypass that check. If it reports 0.5.4 after the install above, the install went into a different env from the one the wrappers activate: activate `$BABS_ENV` and reinstall with `--force-reinstall`. Once a release containing the layout exists, plain `pip install babs` will do.

### 2. Cluster software

Apptainer (or Singularity) for running the containers, and `git-annex` — the wrappers load the `apptainer` module themselves; git-annex comes with the micromamba env. DataLad is installed by `environment_hpc.yml`.

### 3. The container image

Each wrapper looks for its `.sif` file (e.g. `freesurfer-nidm_bidsapp.sif`) by exact filename in `BASE_DIR`, then in `SIF_SEARCH_DIRS` (see `.env` below); a missing image stops the run. Build the image from the matching app repository (each has a `Singularity` recipe and a `setup.py` helper) and drop it next to the scripts. The expected filenames are set at the top of each wrapper script.

### 4. A `.env` file

The wrappers source `.env` from the **current working directory**, so always run them from this repo's root. It is plain bash (no spaces around `=`), so `$HOME` and friends work. A template — replace `<scratch>` with your cluster's scratch/work filesystem and `<data>` with wherever the study's DataLad tree lives. Container images are looked up by exact filename in `BASE_DIR`, then in `SIF_SEARCH_DIRS`; a missing image stops the run:

```bash
BASE_DIR="$HOME/simple2_bidsapp_babs"                    # where you cloned this repo
SCRATCH_DIR_FS="<scratch>/simple2/fs_bidsapp_babs"       # per-app run dirs + logs
SCRATCH_DIR_ANTS="<scratch>/simple2/ants_bidsapp_babs"
SCRATCH_DIR_MRIQC="<scratch>/simple2/mriqc_bidsapp_babs"
SCRATCH_DIR_COMPUTE="<scratch>"                          # where SLURM jobs execute
DATALAD_SET_DIR="<data>/simple2_datalad"                 # root of the study tree
FS_LICENSE="$HOME/license.txt"                           # FreeSurfer runs only
SIF_SEARCH_DIRS=""                                       # optional: more dirs holding .sif images, space-separated
```

### 5. FreeSurfer license (FreeSurfer runs only)

Get a free license from [the FreeSurfer site](https://surfer.nmr.mgh.harvard.edu/registration.html) and point `FS_LICENSE` at it. The wrapper fails fast at launch — not two hours later inside every job — if the variable is unset or the file is missing.

The license cannot be baked into the container image: FreeSurfer licenses are personal (issued per registrant), and the images are shared, so embedding one would redistribute it to every user of the image, which the FreeSurfer license terms don't allow. Binding your own license at runtime is the intended mechanism.

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

Where things land:

- **BABS project** (the deliverable): `<DATALAD_SET_DIR>/<study>/site-<SITE>/derivatives/babs-<app>` — deliberately **undated**. The project's own git history records when everything happened; a date in the folder name is redundant provenance that would have to be corrected later (and BABS projects can't be renamed after `babs init` — absolute paths are baked in). If a project already exists there, `babs init` refuses, which makes redoing a site an explicit decision rather than an accident.
- **Scratch run dir**: `<SCRATCH_DIR_app>/<study>_<RUN_DATE>/` — config copy, container dataset
- **Log**: `<SCRATCH_DIR_app>/babs_script_<RUN_DATE>_<timestamp>.log` — everything the run printed, survives your terminal

`RUN_DATE` (auto-generated as `YYMMDD`, e.g. `260827`) stamps only these per-attempt items — the scratch run dir, compute space, log file, and SLURM job — never the deliverable.

### Knobs

All optional, all environment variables:

| Variable | What it does |
|---|---|
| `RUN_DATE=260827` | Pin the per-attempt date stamp instead of auto-generating it. |
| `BABS_OUTPUT_DIR=/path` | Put the project somewhere other than the default `derivatives/babs-<app>` — e.g. for a deliberate second run of a site whose project already exists. Must be decided before `babs init`; the project cannot be renamed afterwards. |
| `BABS_SKIP_CHECK_SETUP=1` | **Currently required for every run.** `babs check-setup` crashes on the PR #369 study layout (it hardcodes a `inputs/data` path that no longer exists). The wrapper prints a reminder when it skips. |
| `BABS_SUBMIT_COUNT=N` | Submit only the first N jobs — a controlled ramp for when an app's memory/time needs are unverified. Measure the first completions, adjust the config, then `babs submit` the rest into the same project. |
| `BABS_LIST_SUB_FILE=/path.csv` | Restrict the project to the subjects in a CSV — `sub_id` column, plus `ses_id` for session-level projects. For pilots and re-runs, and **effectively required for any site where some subjects/sessions lack the required modality**: babs does *not* apply the config's `required_files` when it builds the inclusion list ([babs#314](https://github.com/PennLINC/babs/issues/314)), so without a pre-computed list every `sub-*/ses-*` directory becomes a job, including ones with no T1w that can only fail. Build the list by globbing the raw dataset (e.g. keep pairs matching `anat/*_T1w.nii*`). |
| `BABS_ENV=name` | Micromamba env holding babs (default `babs`). |
| `BABS_NIDM_DERIV=name` | Which NIDM derivative under `derivatives/` to augment (default `nidm_4.5.0`). This names an existing input folder, `site-<SITE>/derivatives/<name>`; it does not follow the PyNIDM installed on the host, which the BABS jobs never use. See [NIDM versions](#nidm-versions). |

## While the jobs run

Check on things from the project directory:

```bash
micromamba activate babs
cd <DATALAD_SET_DIR>/<study>/site-<SITE>/derivatives/babs-<app>
babs status
```

Two SLURM realities to know about:

**Preemption is expected.** The configs use `mit_preemptable` (591 nodes, 2-day ceiling) rather than `mit_normal` (50 nodes, 12 h) — more throughput, occasional casualties. Every config also sets `#SBATCH --no-requeue`, and must: the partition requeues preempted jobs under the *same* SLURM id, the job then recomputes the same branch name, and its `mkdir` fails. `--no-requeue` turns preemption into a clean failure that can simply be resubmitted. (Of the 38 Caltech FreeSurfer jobs, 4 were preempted; all completed on resubmission.)

**Never `babs submit` while any earlier task is still PENDING.** Each array task discovers *which subject/session it is* only when it starts, by reading its row of the shared `code/job_submit.csv` — and every `babs submit` call rewrites that file with just its own rows ([babs#408](https://github.com/PennLINC/babs/issues/408)). A pending task from an earlier array will then silently run the wrong pair (observed: a duplicate of another job, while its own pair was never processed). Newer babs offers `--select` and `--skip-running-jobs`, which make mid-run submission *possible* — but they do not protect pending tasks' identity, so the safe rule stays: submit in rounds, only when nothing of this project is pending. Tasks already RUNNING are safe (they have read their row). If a duplicate slips through, `scancel` it before it finishes (branches push at job end) and resubmit the orphaned pair later.

So when a preemption notice arrives mid-run, there is nothing to do yet. Wait for the whole array to finish, then run one batch round:

```bash
babs status     # refreshes the job table, marks the failures
babs submit     # resubmits exactly the subjects without results
```

Repeat if the resubmitted round itself loses jobs to preemption.

## After the jobs finish: post-processing

**The harvest script lives in the dataset, not in this repo** — `<DATALAD_SET_DIR>/<study>/site-<SITE>/code/post_babs.sh` — and that's deliberate: it's per-site, it's owned by the data manager, and two divergent copies of it is how a study ends up half-harvested.

```bash
micromamba activate babs
<site>/code/post_babs.sh <site>/derivatives/babs-<app>
```

It merges the per-job result branches, syncs the local checkout with the output RIA, fetches and unzips the result zips (one `sub-<id>/` per subject), drops the now-redundant zip content, and commits the site dataset's updated submodule pointer. It is safe to re-run: an interrupted harvest resumes, and an already-harvested project is detected rather than re-fetched.

Failure modes it already handles — the reason not to reimplement it:

- **`git-annex` must be on PATH.** These datasets set `filter.annex.process`, so any checkout or rebase shells out to git-annex; without it, git quietly empties tracked files mid-operation.
- **`babs merge` is not idempotent.** It deletes the `job-*` branches from the output RIA once merged, so a second invocation claims no job ever finished. The script counts the RIA's remaining job branches instead of believing that message.
- **Local and RIA histories diverge routinely** (saving `code/` after submission). The script fast-forwards when possible and auto-replays local commits only when they're confined to `code/`, leaving a timestamped backup ref either way.
- **Incremental harvests work.** Already-extracted subjects are detected by directory, so a re-run after a second batch of jobs extracts only the new subjects instead of re-fetching tens of GB.

There is deliberately **no merged-TTL step**: the deliverable is the per-subject `sub-<id>/nidm.ttl` files, which downstream tools query as a group. Nothing consumes a concatenated `nidm_merge.ttl`, so none is produced.

## Per-app configuration

Each app's YAML config sets its SLURM resources, verified against real runs:

| Config | Resources | Notes |
|---|---|---|
| `config_freesurfer-nidm.yaml` | 8 CPUs, 32 GB, 6 h | needs `FS_LICENSE`; measured 2.5–3.5 h; peak ~29 GB (Caltech, 1 T1w) up to ~31.3 GB (ONRC_2, 5 T1w runs) — sites with many T1w runs per session sit close to the 32 GB ceiling |
| `config_ants-nidm.yaml` | 16 CPUs, 48 GB, 4 h, 1 GPU | registration is FireANTs on CUDA, so a GPU is required (`--gres=gpu:1` plus `--nv`); the app fails at start without one. The wrapper runs `ants-nidm_bidsapp-0.2.0.sif` (outputs zipped as `0-2-0`) and stops if that image is missing; `ANTS_VERSION=X.Y.Z` selects `ants-nidm_bidsapp-X.Y.Z.sif` and sets the container name and zip version to match, so reproducing the 0.1.0 Caltech run means providing that image as `ants-nidm_bidsapp-0.1.0.sif` and setting `ANTS_VERSION=0.1.0` |
| `config_mriqc-nidm.yaml` | 12 CPUs, 20 GB, 30 min | measured ~4–5 min and ~10.4 GB peak (Caltech); the allocation must stay above MRIQC's own `--mem 16G` |

The wrappers substitute the environment-specific values (paths, license, session flag) into a copy of the config at launch; the copy lands in the scratch run directory so every run records exactly what it used.

### NIDM versions

Two separate things carry a NIDM version, and they must agree:

- **The input records.** Each site's `derivatives/nidm_<version>` folder holds the per-subject `nidm.ttl` files the apps augment, written by the PyNIDM release named in the folder. `BABS_NIDM_DERIV` selects the folder; it changes only when someone regenerates the inputs.
- **The PyNIDM inside each container.** All three apps pin `pynidm==4.5.0` in their own repositories. This is the PyNIDM that reads and writes NIDM during a job. A PyNIDM installed in your host env has no effect on BABS runs.

Moving to a new PyNIDM release (e.g. 5.0.0) therefore means: regenerate each site's inputs into `derivatives/nidm_5.0.0`, update the three app repositories and rebuild their images, then set `BABS_NIDM_DERIV=nidm_5.0.0` (and update the default in `babs_common.sh`). Don't feed records from one PyNIDM version to containers built with another. For 5.0 specifically, MRIQC (which only calls `csv2nidm`) should need just the pin change, but the ANTs and FreeSurfer converters (`ants_seg_to_nidm`, `segstats_jsonld`) import `nidm.core` and `nidm.experiment`, which 5.0 removes, so they need a code port first.

## Adding a new BIDS App

1. Create `config_<app>-nidm.yaml` (start from an existing one).
2. Create `<app>-nidm_babs_script.sh` from an existing wrapper — the app-specific part is just the block of variables at the top: `APP_NAME`, `SCRATCH_DIR`, `CONTAINER_DS_NAME`, `CONTAINER_NAME`, `SIF_FILENAME`, `SIF_ALT_PATHS`.
3. Add the matching `SCRATCH_DIR_<APP>` to `.env`.

Everything else — argument parsing, container dataset setup, config substitution, init, submit — comes from `babs_common.sh`.
