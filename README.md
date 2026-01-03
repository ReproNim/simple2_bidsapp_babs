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
├── post_babs.sh                  # Post-processing script
└── .env                          # Environment variables
```

## Environment Variables (.env)

Create a `.env` file in the project directory:

```bash
BASE_DIR='/home/yibei/simple2_bidsapp_babs'
SCRATCH_DIR_FS='/orcd/scratch/bcs/001/yibei/simple2/fs_bidsapp_babs'
SCRATCH_DIR_ANTS='/orcd/scratch/bcs/001/yibei/simple2/ants_bidsapp_babs'
SCRATCH_DIR_MRIQC='/orcd/scratch/bcs/001/yibei/simple2/mriqc_bidsapp_babs'
SCRATCH_DIR_COMPUTE='/orcd/scratch/bcs/001/yibei/'
DATA_DIR='/orcd/data/satra/002/datasets/simple2'
DATALAD_SET_DIR='/orcd/data/satra/002/datasets/simple2_datalad'
```

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

2. **FreeSurfer License**: Located at `/orcd/scratch/bcs/001/yibei/prettymouth_babs/license.txt`

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
