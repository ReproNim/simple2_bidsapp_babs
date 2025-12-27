#!/bin/bash
if [ -f ".env" ]; then
    source .env
fi

# Set up logging - redirect all further output to a log file while still showing in console
LOG_FILE="$SCRATCH_DIR_MRIQC/babs_script1226_$(date +%Y%m%d_%H%M%S).log"
echo "=== Script started at $(date) ===" | tee $LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Environment: SCRATCH_DIR=$SCRATCH_DIR_MRIQC, BASE_DIR=$BASE_DIR"

# Accept dataset name and site name as arguments
SITE_NAME="$1"  # Accept site name as first argument
DATASET_NAME="$2"  # Accept dataset name as second argument
SCRATCH_DIR=$SCRATCH_DIR_MRIQC

if [ -z "$SITE_NAME" ] || [ -z "$DATASET_NAME" ]; then
    echo "Error: Missing arguments. Usage: $0 <site_name> <dataset_name>"
    exit 1
fi

echo "Processing site: $SITE_NAME for dataset: $DATASET_NAME"

source ~/.bashrc
micromamba activate babs
mkdir -p $SCRATCH_DIR/${DATASET_NAME}_1226
mkdir -p $SCRATCH_DIR_COMPUTE/mriqc_compute_1226
cd $SCRATCH_DIR/${DATASET_NAME}_1226
echo "Current directory: $PWD"

# Check if container setup is already done
if [ -d "${PWD}/mriqc_bidsapp-container" ] && [ -f "${PWD}/mriqc_bidsapp-container/.datalad/config" ] && grep -q "mriqc-nidm-bidsapp-0-1-0" "${PWD}/mriqc_bidsapp-container/.datalad/config" 2>/dev/null; then
    echo "Container already set up, skipping container setup steps."
else
    echo "Setting up container..."
    if [ ! -f "${PWD}/mriqc-nidm_bidsapp1226.sif" ]; then
        if [ -f "/home/yibei/simple2_bidsapp_babs/mriqc-nidm_bidsapp1226.sif" ]; then
            echo "Copying mriqc-nidm_bidsapp1226.sif from simple2_bidsapp_babs directory"
            cp /home/yibei/simple2_bidsapp_babs/mriqc-nidm_bidsapp1226.sif .
        elif [ -f "/orcd/home/002/yibei/simple2_bidsapp_babs/mriqc-nidm_bidsapp1226.sif" ]; then
            echo "Copying mriqc-nidm_bidsapp1226.sif from orcd directory"
            cp /orcd/home/002/yibei/simple2_bidsapp_babs/mriqc-nidm_bidsapp1226.sif .
        else
            echo "ERROR: Cannot find container file. Please ensure mriqc-nidm_bidsapp1226.sif exists."
            exit 1
        fi
    fi

    # Create the container dataset if it doesn't exist
    if [ ! -d "${PWD}/mriqc_bidsapp-container" ]; then
        datalad create -D "MRIQC-NIDM BIDS App 1226" mriqc_bidsapp-container
    fi

    cd mriqc_bidsapp-container
    # Add the container if it's not already added
    if ! datalad containers-list 2>/dev/null | grep -q "mriqc-nidm-bidsapp-0-1-0"; then
        datalad containers-add \
            --url ${PWD}/../mriqc-nidm_bidsapp1226.sif \
            mriqc-nidm-bidsapp-0-1-0
    fi
    cd ../

    # Remove the SIF file if it exists
    if [ -f "${PWD}/mriqc-nidm_bidsapp1226.sif" ]; then
        rm -rf mriqc-nidm_bidsapp1226.sif
    fi
fi

# Define origin URLs with expanded variables
BIDS_ORIGIN="$DATALAD_SET_DIR/$DATASET_NAME/site-$SITE_NAME/sourcedata/raw"
NIDM_ORIGIN="$DATALAD_SET_DIR/$DATASET_NAME/site-$SITE_NAME/derivatives/nidm"
COMPUTE_SPACE="$SCRATCH_DIR_COMPUTE/mriqc_compute_1226"

# Verify BIDS dataset exists
if [ ! -d "$BIDS_ORIGIN" ]; then
    echo "ERROR: BIDS dataset not found at $BIDS_ORIGIN"
    exit 1
fi

# Create the MRIQC BIDS App config YAML file if it doesn't exist
CONFIG_PATH="$SCRATCH_DIR/${DATASET_NAME}_1226/config_mriqc1226.yaml"
if [ ! -f "$CONFIG_PATH" ]; then
    echo "Creating MRIQC BIDS App config YAML file..."
    cat > "$CONFIG_PATH" << EOL
# This is a config yaml file for MRIQC BIDS App (updated 1226)
# Input datasets configuration
input_datasets:
    BIDS:
        required_files:
            - "anat/*_T1w.nii*"
        is_zipped: false
        origin_url: "$BIDS_ORIGIN"
        path_in_babs: inputs/data/BIDS
    NIDM:
        required_files:
            - "nidm.ttl"
        is_zipped: false
        origin_url: "$NIDM_ORIGIN"
        path_in_babs: inputs/data/NIDM
# Arguments passed to the application inside the container
bids_app_args:
    \$SUBJECT_SELECTION_FLAG: "--participant_label"
    --mem: "16G"
    --nprocs: "12"
    --omp-nthreads: "8"
singularity_args:
    - --userns
    - --no-home
    - --writable-tmpfs
# Output foldername(s) to be zipped:
zip_foldernames:
    mriqc_nidm: "0-1-0"
# How much cluster resources it needs:
cluster_resources:
    interpreting_shell: "/bin/bash"
    customized_text: |
        #SBATCH --partition=mit_preemptable
        #SBATCH --cpus-per-task=12
        #SBATCH --mem=18G
        #SBATCH --time=00:25:00
        #SBATCH --job-name=mriqc_babs_1226
# Necessary commands to be run first:
script_preamble: |
    source ~/.bashrc
    micromamba activate babs
    module load apptainer
# Where to run the jobs:
job_compute_space: $COMPUTE_SPACE
required_files:
    \$INPUT_DATASET_#1:
        - "anat/*_T1w.nii*"
# Alert messages that might be found in log files of failed jobs:
alert_log_messages:
    stdout:
        - "ERROR:"
        - "Cannot allocate memory"
        - "Numerical result out of range"
EOL
    echo "YAML config file created at $CONFIG_PATH"
    echo "BIDS origin URL: $BIDS_ORIGIN"
    echo "NIDM origin URL: $NIDM_ORIGIN"
else
    echo "Config file already exists at $CONFIG_PATH, skipping creation"
fi

cd $SCRATCH_DIR/${DATASET_NAME}_1226

# Check if NIDM directory exists for incremental NIDM building
NIDM_DIR="$DATALAD_SET_DIR/$DATASET_NAME/site-$SITE_NAME/derivatives/nidm"
if [ -d "$NIDM_DIR" ] && [ -f "$NIDM_DIR/nidm.ttl" ]; then
    echo "Found NIDM directory at $NIDM_DIR - NIDM will be built incrementally"
else
    echo "No NIDM directory found - NIDM will be created from scratch"
fi

# Initialize BABS with the dataset-specific output directory
babs init \
    --container_ds ${PWD}/mriqc_bidsapp-container \
    --container_name mriqc-nidm-bidsapp-0-1-0 \
    --container_config $SCRATCH_DIR/${DATASET_NAME}_1226/config_mriqc1226.yaml \
    --processing_level subject \
    --queue slurm \
    $SCRATCH_DIR/${DATASET_NAME}_1226/mriqc_bidsapp_site-${SITE_NAME}_1226/

cd $SCRATCH_DIR/${DATASET_NAME}_1226/mriqc_bidsapp_site-${SITE_NAME}_1226

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
echo "Output directory: $SCRATCH_DIR/${DATASET_NAME}_1226/mriqc_bidsapp_site-${SITE_NAME}_1226/"
echo "Log file: $LOG_FILE"
