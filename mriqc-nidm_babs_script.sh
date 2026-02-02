#!/bin/bash
# MRIQC-NIDM BABS Script
# Usage: ./mriqc-nidm_babs_script.sh <site_name> <dataset_name> [processing_level]
#
# Arguments:
#   site_name         - Site identifier (e.g., Caltech, Brown)
#   dataset_name      - Dataset identifier (e.g., study-ABIDE, study-ADHD200)
#   processing_level  - Optional: "subject" or "session" (default: subject)
#
# Examples:
#   Single-session dataset:  ./mriqc-nidm_babs_script.sh Caltech study-ABIDE
#   Multi-session dataset:   ./mriqc-nidm_babs_script.sh Brown study-ADHD200 session
#
# Optional environment variable:
#   RUN_DATE=YYMMDD - Use specific date instead of auto-generated

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common functions library
source "${SCRIPT_DIR}/babs_common.sh"

# ============================================================================
# MRIQC-NIDM-specific configuration
# ============================================================================
APP_NAME="mriqc-nidm"
SCRATCH_DIR="$SCRATCH_DIR_MRIQC"
CONTAINER_DS_NAME="mriqc-nidm_bidsapp-container"
CONTAINER_NAME="mriqc-nidm-bidsapp-0-1-0"
SIF_FILENAME="mriqc-nidm_bidsapp.sif"
SIF_ALT_PATHS=(
    "/orcd/home/002/yibei/simple2_bidsapp_babs"
    "/home/yibei/simple2_bidsapp_babs"
)

# ============================================================================
# Parse arguments
# ============================================================================
SITE_NAME="$1"
DATASET_NAME="$2"
PROCESSING_LEVEL="${3:-subject}"  # Default to "subject" if not provided

# Initialize run date (auto-generate or use env var)
babs_init_run_date

# Validate processing level
if [ "$PROCESSING_LEVEL" != "subject" ] && [ "$PROCESSING_LEVEL" != "session" ]; then
    echo "ERROR: processing_level must be either 'subject' or 'session'" >&2
    echo "  Provided: '$PROCESSING_LEVEL'" >&2
    echo "  Usage: $0 <site_name> <dataset_name> [processing_level]" >&2
    echo "  Example: $0 Caltech study-ABIDE subject" >&2
    echo "  Example: $0 Brown study-ADHD200 session" >&2
    exit 1
fi

# Validate arguments
babs_validate_args "$SITE_NAME" "$DATASET_NAME" "$PROCESSING_LEVEL"

# ============================================================================
# Set up logging
# ============================================================================
babs_setup_logging "$SCRATCH_DIR" "$APP_NAME"
echo "Environment: SCRATCH_DIR=$SCRATCH_DIR, BASE_DIR=$BASE_DIR"
echo "Processing site: $SITE_NAME for dataset: $DATASET_NAME"
echo "Processing level: $PROCESSING_LEVEL"

# ============================================================================
# Set up environment
# ============================================================================
babs_setup_env

# ============================================================================
# Create directories
# ============================================================================
RUN_DIR="${SCRATCH_DIR}/${DATASET_NAME}_${RUN_DATE}"
COMPUTE_DIR="${SCRATCH_DIR_COMPUTE}/mriqc-nidm_compute_${RUN_DATE}"

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

# Verify BIDS dataset exists
if [ ! -d "$BIDS_ORIGIN" ]; then
    echo "ERROR: BIDS dataset not found at $BIDS_ORIGIN"
    exit 1
fi

CONFIG_PATH="${RUN_DIR}/config_mriqc-nidm.yaml"

babs_prepare_yaml_config \
    "${SCRIPT_DIR}/config_mriqc-nidm.yaml" \
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
OUTPUT_DIR="${RUN_DIR}/mriqc-nidm_bidsapp_${SITE_NAME}_${RUN_DATE}"

babs_init_and_submit \
    "${PWD}/${CONTAINER_DS_NAME}" \
    "$CONTAINER_NAME" \
    "$CONFIG_PATH" \
    "$OUTPUT_DIR" \
    "$PROCESSING_LEVEL"

# ============================================================================
# Print completion message
# ============================================================================
babs_print_completion "$OUTPUT_DIR"
