# BABS Scripts for BIDS Apps with NIDM

BABS (BIDS App Bootstrap) scripts for running ANTs-NIDM, FreeSurfer-NIDM, and MRIQC-NIDM on SLURM clusters.

## Prerequisites

Before running any pipeline:

1. **BABS environment**: install per the Environment Setup section below.
2. **Apptainer/Singularity**: available on the cluster (the scripts run `module load apptainer`).
3. **`.env` file**: copy the template in the Environment Variables section below and edit every path for your cluster — none of these paths are portable.
4. **Container `.sif` files**: place `freesurfer-nidm_bidsapp.sif`, `ants-nidm_bidsapp.sif`, and/or `mriqc-nidm_bidsapp.sif` in `BASE_DIR` (or one of the per-script `SIF_ALT_PATHS`).
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

## Post-Processing

After jobs complete, use the post-processing script:

```bash
./post_babs.sh <babs_run_dir>

# Example:
./post_babs.sh /orcd/scratch/bcs/001/yibei/simple2/mriqc_bidsapp_babs/study-ABIDE_1230/mriqc-nidm_bidsapp_Caltech_1230
```

This will:
1. Run `babs merge` to combine results
2. Clone output RIA store
3. Extract zipped subject files
4. Merge NIDM TTL files

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

2. **FreeSurfer License**: set `FS_LICENSE` in `.env` to the path of your license file. The FreeSurfer-NIDM script validates this at startup and aborts before submitting jobs if the path is unset or missing.

3. **NIDM Incremental Building**: If an NIDM directory exists at the target location, NIDM results will be built incrementally.

4. **SLURM Partition**: Jobs use `mit_preemptable` partition by default (configurable in YAML files).

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
