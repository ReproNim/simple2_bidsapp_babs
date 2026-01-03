#!/bin/bash
# FreeSurfer-NIDM BABS Script
# Usage: ./freesurfer-nidm_babs_script.sh <site_name> <dataset_name>
# Example: ./freesurfer-nidm_babs_script.sh Caltech study-ABIDE
#
# Optional: Set RUN_DATE environment variable to use a specific date instead of auto-generated
#   export RUN_DATE=1230
#   ./freesurfer-nidm_babs_script.sh Caltech study-ABIDE

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common functions library
source "${SCRIPT_DIR}/babs_common.sh"

# ============================================================================
# FreeSurfer-NIDM-specific configuration
# ============================================================================
APP_NAME="freesurfer-nidm"
SCRATCH_DIR="$SCRATCH_DIR_FS"
CONTAINER_DS_NAME="freesurfer-nidm_bidsapp-container"
CONTAINER_NAME="freesurfer-nidm-bidsapp-0-1-0"
SIF_FILENAME="freesurfer-nidm_bidsapp.sif"
SIF_ALT_PATHS=(
    "/orcd/home/002/yibei/simple2_bidsapp_babs"
    "/home/yibei/simple2_bidsapp_babs"
    "/orcd/home/002/yibei/freesurfer_bidsapp"
    "/home/yibei/freesurfer_bidsapp"
)

# ============================================================================
# Parse arguments
# ============================================================================
SITE_NAME="$1"
DATASET_NAME="$2"

# Initialize run date (auto-generate or use env var)
babs_init_run_date

# Validate arguments
babs_validate_args "$SITE_NAME" "$DATASET_NAME"

# ============================================================================
# Set up logging
# ============================================================================
babs_setup_logging "$SCRATCH_DIR" "$APP_NAME"
echo "Environment: SCRATCH_DIR=$SCRATCH_DIR, BASE_DIR=$BASE_DIR"
echo "Processing site: $SITE_NAME for dataset: $DATASET_NAME"

# ============================================================================
# Set up environment
# ============================================================================
babs_setup_env

# ============================================================================
# Create directories
# ============================================================================
RUN_DIR="${SCRATCH_DIR}/${DATASET_NAME}_${RUN_DATE}"
COMPUTE_DIR="${SCRATCH_DIR_COMPUTE}/freesurfer-nidm_compute_${RUN_DATE}"

mkdir -p "$RUN_DIR"
mkdir -p "$COMPUTE_DIR"
cd "$RUN_DIR"
echo "Current directory: $PWD"

# ============================================================================
# Set up container
# ============================================================================
babs_setup_container \
    "$APP_NAME" \
    "$CONTAINER_DS_NAME" \
    "$CONTAINER_NAME" \
    "$SIF_FILENAME" \
    "${SIF_ALT_PATHS[@]}"

# ============================================================================
# Prepare YAML config
# ============================================================================
# Define paths for YAML substitution
BIDS_ORIGIN="${DATALAD_SET_DIR}/${DATASET_NAME}/site-${SITE_NAME}/sourcedata/raw"
NIDM_ORIGIN="${DATALAD_SET_DIR}/${DATASET_NAME}/site-${SITE_NAME}/derivatives/nidm"

CONFIG_PATH="${RUN_DIR}/config_freesurfer-nidm.yaml"

babs_prepare_yaml_config \
    "${SCRIPT_DIR}/config_freesurfer-nidm.yaml" \
    "$CONFIG_PATH" \
    "BIDS_ORIGIN=${BIDS_ORIGIN}" \
    "NIDM_ORIGIN=${NIDM_ORIGIN}" \
    "COMPUTE_SPACE=${COMPUTE_DIR}" \
    "RUN_DATE=${RUN_DATE}"

echo "BIDS origin URL: $BIDS_ORIGIN"
echo "NIDM origin URL: $NIDM_ORIGIN"

# ============================================================================
# Check NIDM directory
# ============================================================================
babs_check_nidm "$DATASET_NAME" "$SITE_NAME"

# ============================================================================
# Initialize BABS and submit
# ============================================================================
OUTPUT_DIR="${RUN_DIR}/freesurfer-nidm_bidsapp_${SITE_NAME}_${RUN_DATE}"

babs_init_and_submit \
    "${PWD}/${CONTAINER_DS_NAME}" \
    "$CONTAINER_NAME" \
    "$CONFIG_PATH" \
    "$OUTPUT_DIR" \
    "subject"

# ============================================================================
# Print completion message
# ============================================================================
babs_print_completion "$OUTPUT_DIR"
