#!/bin/bash
if [ -f ".env" ]; then
    source .env
fi

# Set up logging - redirect all further output to a log file while still showing in console
LOG_FILE="$SCRATCH_DIR_FS/babs_script1218_$(date +%Y%m%d_%H%M%S).log"
echo "=== Script started at $(date) ===" | tee $LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Environment: SCRATCH_DIR=$SCRATCH_DIR_FS, BASE_DIR=$BASE_DIR"

# Accept dataset name and input path as arguments
SITE_NAME="$1"  # Accept input path as first argument
DATASET_NAME="$2"  # Accept dataset name as second argument
SCRATCH_DIR=$SCRATCH_DIR_FS

if [ -z "$SITE_NAME" ] || [ -z "$DATASET_NAME" ]; then
    echo "Error: Missing arguments. Usage: $0 <site_name> <dataset_name>"
    exit 1
fi

# Extract site name from input path
echo "Processing site: $SITE_NAME for dataset: $DATASET_NAME"

source ~/.bashrc
micromamba activate babs
mkdir -p $SCRATCH_DIR/${DATASET_NAME}_1218
mkdir -p $SCRATCH_DIR_COMPUTE/freesurfer_compute_1218
cd $SCRATCH_DIR/${DATASET_NAME}_1218
echo "Current directory: $PWD"

# Check if container setup is already done
if [ -d "${PWD}/fs_bidsapp-container" ] && [ -f "${PWD}/fs_bidsapp-container/.datalad/config" ] && grep -q "freesurfer-bidsapp-0-1-0" "${PWD}/fs_bidsapp-container/.datalad/config" 2>/dev/null; then
    echo "Container already set up, skipping container setup steps."
else
    echo "Setting up container..."
    # Use the specific 1218 version of the container
    if [ ! -f "${PWD}/freesurfer_bidsapp1218.sif" ]; then
        # Check for the 1218 version first
        if [ -f "/orcd/home/002/yibei/simple2_bidsapp_babs/freesurfer_bidsapp1218.sif" ]; then
            echo "Copying freesurfer_bidsapp1218.sif from simple2_bidsapp_babs directory"
            cp /orcd/home/002/yibei/simple2_bidsapp_babs/freesurfer_bidsapp1218.sif .
        elif [ -f "/orcd/home/002/yibei/freesurfer_bidsapp/freesurfer_bidsapp.sif" ]; then
            echo "Copying freesurfer_bidsapp.sif from freesurfer_bidsapp directory and renaming to 1218"
            cp /orcd/home/002/yibei/freesurfer_bidsapp/freesurfer_bidsapp.sif ./freesurfer_bidsapp1218.sif
        elif [ -f "/home/yibei/freesurfer_bidsapp/freesurfer_bidsapp.sif" ]; then
            echo "Copying freesurfer_bidsapp.sif from home directory and renaming to 1218"
            cp /home/yibei/freesurfer_bidsapp/freesurfer_bidsapp.sif ./freesurfer_bidsapp1218.sif
        else
            echo "ERROR: Cannot find container file. Please ensure freesurfer_bidsapp1218.sif exists in /orcd/home/002/yibei/simple2_bidsapp_babs/"
            exit 1
        fi
    fi

    # Create the container dataset if it doesn't exist
    if [ ! -d "${PWD}/fs_bidsapp-container" ]; then
        datalad create -D "freesurfer BIDS App 1218" fs_bidsapp-container
    fi

    cd fs_bidsapp-container
    # Add the container if it's not already added
    if ! datalad containers-list 2>/dev/null | grep -q "freesurfer-bidsapp-0-1-0"; then
        datalad containers-add \
            --url ${PWD}/../freesurfer_bidsapp1218.sif \
            freesurfer-bidsapp-0-1-0
    fi
    cd ../

    # Remove the SIF file if it exists
    if [ -f "${PWD}/freesurfer_bidsapp1218.sif" ]; then
        rm -rf freesurfer_bidsapp1218.sif
    fi
fi

# Create the FreeSurfer BIDS App config YAML file if it doesn't exist
CONFIG_PATH="$SCRATCH_DIR/${DATASET_NAME}_1218/config_fs1218.yaml"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Creating FreeSurfer BIDS App config YAML file..."
    cat > "$CONFIG_PATH" << EOL
# This is a config yaml file for FreeSurfer BIDS App (updated 1218)
# Input datasets configuration
input_datasets:
    BIDS:
        required_files:
            - "anat/*_T1w.nii*"
        is_zipped: false
        origin_url: "$DATALAD_SET_DIR/$DATASET_NAME/$SITE_NAME/sourcedata/raw"
        path_in_babs: inputs/data/BIDS
    NIDM:
        required_files:
            - "nidm.ttl"
        is_zipped: false
        origin_url: "$DATALAD_SET_DIR/$DATASET_NAME/$SITE_NAME/derivatives/nidm"
        path_in_babs: inputs/data/NIDM
# Arguments passed to the application inside the container
bids_app_args:
    "\$SUBJECT_SELECTION_FLAG": "--participant_label"
    --fs-license-file: "/orcd/scratch/bcs/001/yibei/prettymouth_babs/license.txt"
    --skip-bids-validation: ""
    # Note: NIDM will be generated automatically if NIDM/ directory exists
singularity_args:
    - --userns
    - --no-home
    - --writable-tmpfs
# Output foldername(s) to be zipped:
zip_foldernames:
    freesurfer_bidsapp: "0-1-0"
# How much cluster resources it needs:
cluster_resources:
    interpreting_shell: "/bin/bash"
    customized_text: |
        #SBATCH --partition=mit_preemptable
        #SBATCH --cpus-per-task=8
        #SBATCH --mem=24G
        #SBATCH --time=03:30:00
        #SBATCH --job-name=fs_bidsapp_1218
# Necessary commands to be run first:
script_preamble: |
    source ~/.bashrc
    micromamba activate babs
    module load apptainer
# Where to run the jobs:
job_compute_space: "/orcd/scratch/bcs/001/yibei/freesurfer_compute_1218"
required_files:
    "\$INPUT_DATASET_#1":
        - "anat/*_T1w.nii*"
# Alert messages that might be found in log files of failed jobs:
alert_log_messages:
    stdout:
        - "ERROR:"
        - "Cannot allocate memory"
        - "mris_curvature_stats: Could not open file"
        - "Numerical result out of range"
        - "FreeSurfer failed"
        - "recon-all: error"
        - "NIDM conversion failed"
EOL
    echo "YAML config file created at $CONFIG_PATH"
else
    echo "Config file already exists at $CONFIG_PATH, skipping creation"
fi

cd $SCRATCH_DIR/${DATASET_NAME}_1218

# Check if NIDM directory exists for incremental NIDM building
NIDM_DIR="$DATALAD_SET_DIR/$DATASET_NAME/$SITE_NAME/derivatives/nidm"
if [ -d "$NIDM_DIR" ] && [ -f "$NIDM_DIR/nidm.ttl" ]; then
    echo "Found NIDM directory at $NIDM_DIR - NIDM will be built incrementally"
else
    echo "No NIDM directory found - NIDM will be created from scratch"
fi

# Initialize BABS with the dataset-specific output directory
# Note: In BABS 0.5.x, we don't use --datasets flag, instead datasets are configured in YAML
babs init \
    --container_ds ${PWD}/fs_bidsapp-container \
    --container_name freesurfer-bidsapp-0-1-0 \
    --container_config $SCRATCH_DIR/${DATASET_NAME}_1218/config_fs1218.yaml \
    --processing_level subject \
    --queue slurm \
    $SCRATCH_DIR/${DATASET_NAME}_1218/fs_bidsapp_${SITE_NAME}_1218/

cd $SCRATCH_DIR/${DATASET_NAME}_1218/fs_bidsapp_${SITE_NAME}_1218

# Optional: First check the setup before submitting
echo "Checking BABS setup..."
babs check-setup ${PWD} --job_test

# If babs check-setup is successful, submit all jobs
if [ $? -eq 0 ]; then
    echo "BABS setup check successful, submitting all jobs..."
    babs submit
else
    echo "BABS setup check failed. Please review the errors above."
    echo "You can manually submit after fixing issues with: babs submit --all"
    exit 1
fi

echo "=== Script completed at $(date) ===" | tee -a $LOG_FILE
echo "Output directory: $SCRATCH_DIR/${DATASET_NAME}_1218/fs_bidsapp_${SITE_NAME}_1218/"
echo "Log file: $LOG_FILE"