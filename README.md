# BABS Scripts for BIDS Apps with NIDM

BABS (BIDS App Bootstrap) scripts for running ANTs-NIDM, FreeSurfer-NIDM, and MRIQC-NIDM on SLURM clusters.

## Environment Setup

```bash
# Download BABS HPC environment file
wget https://raw.githubusercontent.com/PennLINC/babs/refs/heads/main/environment_hpc.yml

# Create environment from YAML
micromamba create -f environment_hpc.yml -y

# Install BABS
micromamba activate babs
pip install babs
```

## Project Structure

```
simple2_bidsapp_babs/
├── babs_common.sh                # Shared functions library
├── ants-nidm_babs_script.sh      # ANTs-NIDM pipeline script
├── freesurfer-nidm_babs_script.sh # FreeSurfer-NIDM pipeline script
├── mriqc-nidm_babs_script.sh     # MRIQC-NIDM pipeline script
├── config_ants-nidm.yaml         # ANTs-NIDM BIDS App configuration
├── config_freesurfer-nidm.yaml   # FreeSurfer-NIDM BIDS App configuration
├── config_mriqc-nidm.yaml        # MRIQC-NIDM BIDS App configuration
└── .env                          # Environment variables
```

## Environment Variables (.env)

Create a `.env` file in the project directory:

```bash
BASE_DIR='/path/of/current/repo/' # e.g., '/home/yibei/simple2_bidsapp_babs'
SCRATCH_DIR = 'path/to/your/output/' # e.g., '/orcd/scratch/bcs/001/yibei/simple2'
SCRATCH_DIR_ANTS= SCRATCH_DIR + 'ants_bidsapp_babs'
SCRATCH_DIR_FS= SCRATCH_DIR + 'fs_bidsapp_babs'
SCRATCH_DIR_MRIQC= SCRATCH_DIR + 'mriqc_bidsapp_babs'
SCRATCH_DIR_COMPUTE= '/path/to/your/computespace' #e.g., '/orcd/scratch/bcs/001/yibei/'
DATALAD_SET_DIR= '/path/to/your/input/data/' # e.g.,'/orcd/data/satra/002/datasets/simple2_datalad'
```

`SCRATCH_DIR_ANTS`, `SCRATCH_DIR_FS`, and `SCRATCH_DIR_MRIQC` are used by the ANTs, FreeSurfer, and MRIQC wrapper scripts respectively. I like to put all of those  three together under `SCRATCH_DIR`, you can reorganize them in whatever way you prefer.

## Usage

### Basic Usage

The run date (YYMMDD format) is **automatically generated** from the current date.

```bash
# ANTs-NIDM pipeline
./ants-nidm_babs_script.sh Caltech study-ABIDE

# FreeSurfer-NIDM pipeline
./freesurfer-nidm_babs_script.sh Caltech study-ABIDE

# MRIQC-NIDM pipeline
./mriqc-nidm_babs_script.sh Caltech study-ABIDE
```

### Override Run Date

To use a specific date instead of auto-generation:

```bash
export RUN_DATE=1230
./ants-nidm_babs_script.sh Caltech study-ABIDE
```

### Arguments

| Argument | Description | Example |
|----------|-------------|---------|
| `<site_name>` | Site identifier | `Caltech` |
| `<dataset_name>` | Dataset name | `study-ABIDE` |

## Output Structure

```
/orcd/scratch/bcs/001/yibei/simple2/
├── ants_bidsapp_babs/
│   └── study-ABIDE_1230/
│       ├── ants-nidm_bidsapp-container/
│       ├── config_ants-nidm.yaml
│       └── ants-nidm_bidsapp_Caltech_1230/    # BABS project directory
├── fs_bidsapp_babs/
│   └── study-ABIDE_1230/
│       ├── freesurfer-nidm_bidsapp-container/
│       ├── config_freesurfer-nidm.yaml
│       └── freesurfer-nidm_bidsapp_Caltech_1230/
└── mriqc_bidsapp_babs/
    └── study-ABIDE_1230/
        ├── mriqc-nidm_bidsapp-container/
        ├── config_mriqc-nidm.yaml
        └── mriqc-nidm_bidsapp_Caltech_1230/
```

## Manual BABS Commands

After the script creates the BABS project directory:

```bash
# Navigate to project directory
cd /orcd/scratch/bcs/001/yibei/simple2/ants_bidsapp_babs/study-ABIDE_1230/ants-nidm_bidsapp_Caltech_1230

# Activate environment
micromamba activate babs

# Check setup
babs check-setup .

# Submit jobs
babs submit

# Check job status
babs status

# Merge results (after completion)
babs merge
```

## BABS project layout

The supplied configs use the configurable BIDS-study layout introduced by
[PennLINC/babs PR #369](https://github.com/PennLINC/babs/pull/369):

```yaml
analysis_path: "."
input_ria_path: ".babs/input_ria"
output_ria_path: ".babs/output_ria"
```

The project directory is therefore the analysis DataLad dataset, input
datasets are installed beneath `sourcedata/`, and internal RIA stores live
beneath `.babs/`. Use a BABS revision containing PR #369 with these configs.
These configs therefore require a BABS revision containing PR #369; the
wrappers activate one (`BABS_ENV`, default `babs-369`). On BABS 0.5.2 the three
settings are silently ignored -- `base.py` hardcodes `analysis_path` and
`input_ria_path`, and nothing rejects the unknown keys -- so you get a
legacy-layout project with no error. The dataset's `post_babs.sh` only supports
this study layout.

For session-level runs, the wrappers add
`$SESSION_SELECTION_FLAG: "--session-label"` to the generated config. They omit
it for subject-level runs because BABS only defines `$sesid` in session jobs.

## Post-Processing

**Do not add a post-processing script here.** The canonical one is maintained
in the dataset itself, per site:

```
<DATALAD_SET_DIR>/<study>/site-<SITE>/code/post_babs.sh
```

Run it against a finished BABS project directory:

```bash
module load git-annex          # required: see below
micromamba activate babs-369
/orcd/data/satra/002/datasets/simple2_datalad/study-ABIDE/site-Caltech/code/post_babs.sh \
    /orcd/data/satra/002/datasets/simple2_datalad/study-ABIDE/site-Caltech/derivatives/babs-<app>_<date>
```

It merges the per-job result branches, syncs the checked-out branch with the
output RIA, fetches and unzips the result zips in place, drops the now-redundant
zip content, and commits the site dataset's submodule pointer.

That script handles a set of failure modes worth knowing about, and is the
reason not to reimplement it:

- `git-annex` must be on PATH. These datasets set `filter.annex.process`, so any
  `git checkout`/`rebase` shells out to `git-annex filter-process`; without it,
  git empties or deletes tracked files partway through.
- git's "dubious ownership" guard trips routinely, because these datasets are
  run by whoever is doing the analysis rather than only by the owner. It is
  checked up front, since the failure is otherwise misdiagnosed as a detached
  HEAD.
- `babs merge` is **not** idempotent: it deletes the `job-*` branches from the
  output RIA once merged, so a second run reports "no successfully finished
  job" for a project where everything in fact finished. It counts the RIA's
  remaining `job-*` branches instead of inferring.
- Local and output-RIA histories diverge normally (saving `code/` after jobs
  were submitted), so `ff-only` legitimately fails; it replays local commits
  when their net effect is confined to `code/`, leaving a timestamped backup ref.
- Re-runs detect already-extracted subjects by directory rather than by annex
  content, so an incremental run still extracts newly finished subjects without
  re-fetching tens of GB only to skip it.


## Configuration Files

Each BIDS App has its own YAML configuration file:

- **config_ants-nidm.yaml** - ANTs normalization settings
  - 8 CPUs, 32GB memory, 18 hours time limit

- **config_freesurfer-nidm.yaml** - FreeSurfer recon-all settings
  - 8 CPUs, 24GB memory, 3.5 hours time limit
  - Requires FreeSurfer license

- **config_mriqc-nidm.yaml** - MRIQC quality control settings
  - 12 CPUs, 18GB memory, 25 minutes time limit

## Important Notes

1. **Git Safe Directories**: For DataLad datasets owned by different users:
   ```bash
   git config --global --add safe.directory '/orcd/data/satra/002/datasets/simple2_datalad/study-ABIDE/Caltech/sourcedata/raw/.git'
   git config --global --add safe.directory '/orcd/data/satra/002/datasets/simple2_datalad/study-ABIDE/Caltech/derivatives/nidm/.git'
   ```

2. **FreeSurfer License**: Located at `/orcd/scratch/bcs/001/yibei/prettymouth_babs/license.txt`

3. **NIDM Incremental Building**: If an NIDM directory exists at the target location, NIDM results will be built incrementally.

4. **SLURM Partition**: Jobs use `mit_preemptable` by default (591 nodes, 2-day
   ceiling) rather than `mit_normal` (50 nodes, 12h). Every config that uses it
   must also pass `#SBATCH --no-requeue`: the partition has
   `PreemptMode=REQUEUE`, a requeued job keeps its SLURM id, and
   `participant_job.sh` then recomputes the same `BRANCH` and fails on its bare
   `mkdir "${BRANCH}"`. `--no-requeue` turns preemption into a clean failure that
   `babs submit` can retry under a new job id. Expect occasional resubmissions.

## Adding a New BIDS App

To add support for a new BIDS App:

1. Create a new config file (e.g., `config_newapp-nidm.yaml`)
2. Create a wrapper script (e.g., `newapp-nidm_babs_script.sh`) based on existing scripts
3. Define app-specific variables:
   - `APP_NAME` (e.g., "newapp-nidm")
   - `SCRATCH_DIR`
   - `CONTAINER_DS_NAME` (e.g., "newapp-nidm_bidsapp-container")
   - `CONTAINER_NAME`
   - `SIF_FILENAME`
   - `SIF_ALT_PATHS`
