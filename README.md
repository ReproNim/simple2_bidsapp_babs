# BABS Scripts for BIDS Apps with NIDM

BABS (BIDS App Bootstrap) wrapper scripts for running the ANTs-NIDM, FreeSurfer-NIDM, and MRIQC-NIDM BIDS Apps on SLURM clusters.

Each `<app>_babs_script.sh` is a one-shot driver that finds the container `.sif`, prepares the BABS YAML from a template, runs `babs init`, and submits jobs. The goal is to get from "I have a BIDS dataset on shared storage" to "jobs are queued on SLURM" in a single command, with all cluster-specific paths factored out into `.env`.

The companion BIDS App container repositories live under [ReproNim](https://github.com/ReproNim):

- [freesurfer-nidm_bidsapp](https://github.com/ReproNim/freesurfer-nidm_bidsapp)
- [ants-nidm_bidsapp](https://github.com/ReproNim/ants-nidm_bidsapp)
- [mriqc-nidm_bidsapp](https://github.com/ReproNim/mriqc-nidm_bidsapp)

Build the `.sif` containers from those repos (each has a `Singularity` file and `python setup.py singularity` build helper), then point this repo at them via `BASE_DIR`.

## Prerequisites

Before running any pipeline:

1. **BABS environment**: install per the Environment Setup section below.
2. **Apptainer/Singularity**: available on the cluster (the scripts run `module load apptainer`).
3. **`.env` file**: copy the template in the Environment Variables section below and edit every path for your cluster — none of these paths are portable.
4. **Container `.sif` files**: build the appropriate container(s) from the ReproNim BIDS App repos linked above and place `freesurfer-nidm_bidsapp.sif`, `ants-nidm_bidsapp.sif`, and/or `mriqc-nidm_bidsapp.sif` in `BASE_DIR` (or one of the per-script `SIF_ALT_PATHS`).
5. **FreeSurfer license** (FreeSurfer-NIDM only): request a free license at https://surfer.nmr.mgh.harvard.edu/registration.html, save it somewhere readable, and point `FS_LICENSE` in `.env` at the file. The FreeSurfer script fails fast at submission time if `FS_LICENSE` is unset or the file is missing.
6. **Input datasets**: BIDS data (and optional NIDM derivatives) available as DataLad datasets under `DATALAD_SET_DIR/<dataset_name>/site-<site_name>/...`.

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
├── post_babs.sh                  # Post-processing script
└── .env                          # Environment variables
```

## Environment Variables (.env)

Create a `.env` file in the project directory. **All paths shown below are examples from MIT ORCD — edit every line for your cluster.**

```bash
# Where this repo lives (fallback location for .sif files)
BASE_DIR='/path/to/simple2_bidsapp_babs'                  # e.g., '/home/yibei/simple2_bidsapp_babs'

# Shared parent for per-app scratch directories
SCRATCH_DIR='/path/to/scratch'                            # e.g., '/orcd/scratch/bcs/001/yibei/simple2'

# Per-app scratch directories where BABS projects are created
SCRATCH_DIR_ANTS="${SCRATCH_DIR}/ants_bidsapp_babs"
SCRATCH_DIR_FS="${SCRATCH_DIR}/fs_bidsapp_babs"
SCRATCH_DIR_MRIQC="${SCRATCH_DIR}/mriqc_bidsapp_babs"

# Compute space for SLURM job working directories
SCRATCH_DIR_COMPUTE='/path/to/compute_space'              # e.g., '/orcd/scratch/bcs/001/yibei/'

# Root of DataLad-versioned input datasets (BIDS + NIDM)
DATALAD_SET_DIR='/path/to/datalad_datasets'               # e.g., '/orcd/data/satra/002/datasets/simple2_datalad'

# FreeSurfer license file (FreeSurfer-NIDM pipeline only)
FS_LICENSE='/path/to/freesurfer/license.txt'
```

`SCRATCH_DIR_ANTS`, `SCRATCH_DIR_FS`, and `SCRATCH_DIR_MRIQC` are read by the ANTs, FreeSurfer, and MRIQC wrapper scripts respectively. The template above derives them from a shared `SCRATCH_DIR` parent for convenience; you can also set them to unrelated paths if your cluster layout requires it.

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

Each wrapper script writes under the corresponding `SCRATCH_DIR_*` from your `.env`. With the shared-parent layout in the template, that resolves to:

```
${SCRATCH_DIR}/
├── ants_bidsapp_babs/                              # = ${SCRATCH_DIR_ANTS}
│   └── <dataset>_<RUN_DATE>/
│       ├── ants-nidm_bidsapp-container/
│       ├── config_ants-nidm.yaml
│       └── ants-nidm_bidsapp_<site>_<RUN_DATE>/    # BABS project directory
├── fs_bidsapp_babs/                                # = ${SCRATCH_DIR_FS}
│   └── <dataset>_<RUN_DATE>/
│       ├── freesurfer-nidm_bidsapp-container/
│       ├── config_freesurfer-nidm.yaml
│       └── freesurfer-nidm_bidsapp_<site>_<RUN_DATE>/
└── mriqc_bidsapp_babs/                             # = ${SCRATCH_DIR_MRIQC}
    └── <dataset>_<RUN_DATE>/
        ├── mriqc-nidm_bidsapp-container/
        ├── config_mriqc-nidm.yaml
        └── mriqc-nidm_bidsapp_<site>_<RUN_DATE>/
```

## Manual BABS Commands

After the script creates the BABS project directory:

```bash
# Navigate to the BABS project directory
cd "${SCRATCH_DIR_ANTS}/<dataset>_<RUN_DATE>/ants-nidm_bidsapp_<site>_<RUN_DATE>"

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

## Post-Processing

After jobs complete, use the post-processing script:

```bash
./post_babs.sh <babs_run_dir>

# Example:
./post_babs.sh "${SCRATCH_DIR_MRIQC}/<dataset>_<RUN_DATE>/mriqc-nidm_bidsapp_<site>_<RUN_DATE>"
```

This will:
1. Run `babs merge` to combine results
2. Clone output RIA store
3. Extract zipped subject files
4. Merge NIDM TTL files

## Configuration Files

Each BIDS App has its own YAML configuration file:

- **config_ants-nidm.yaml** — ANTs normalization settings (8 CPUs, 32 GB, 18 h time limit)
- **config_freesurfer-nidm.yaml** — FreeSurfer recon-all settings (8 CPUs, 24 GB, 3.5 h time limit; requires `FS_LICENSE`)
- **config_mriqc-nidm.yaml** — MRIQC quality control settings (12 CPUs, 18 GB, 25 min time limit)

**SLURM partition**: jobs use `mit_preemptable` by default. Override this for your cluster by editing the `customized_text` block in the relevant config YAML before running the wrapper script.

**Incremental NIDM**: if a DataLad NIDM dataset exists under `${DATALAD_SET_DIR}/<dataset>/site-<site>/derivatives/nidm`, the BIDS App appends to the existing `nidm.ttl` rather than overwriting. Omit (or leave empty) the NIDM input directory to generate NIDM from scratch.

## Caveats

**Git safe directories.** DataLad datasets owned by another user trip git's `safe.directory` check on shared filesystems. If `babs init` or `datalad get` fails with "dubious ownership", whitelist the offending repos once:

```bash
git config --global --add safe.directory "${DATALAD_SET_DIR}/<dataset>/site-<site>/sourcedata/raw/.git"
git config --global --add safe.directory "${DATALAD_SET_DIR}/<dataset>/site-<site>/derivatives/nidm/.git"
```

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
