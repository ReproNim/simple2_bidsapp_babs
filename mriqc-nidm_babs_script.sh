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
#   MRIQC_VERSION=X.Y.Z - Run mriqc-nidm_bidsapp-X.Y.Z.sif (default 0.1.3);
#                         also sets the container name and zip version
#   MRIQC_MAX_VOXEL_SIZE=MM - Pass --max-voxel-size MM (mriqc-nidm 0.1.3+):
#                         leave T1w/T2w images with a voxel dimension above
#                         MM out of MRIQC. Unset (default): every image is
#                         rated. ABIDE II UCLA_Long needs 2.

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
# One variable names the image, the container and the zip version, so a run
# cannot label one version's outputs with another's number.
MRIQC_VERSION="${MRIQC_VERSION:-0.1.3}"
babs_resolve_version MRIQC_VERSION "$MRIQC_VERSION"
CONTAINER_NAME="mriqc-nidm-bidsapp-${ZIP_VERSION}"
SIF_FILENAME="mriqc-nidm_bidsapp-${MRIQC_VERSION}.sif"
SIF_ALT_PATHS=()   # searched after BASE_DIR; add more via SIF_SEARCH_DIRS in .env

# ============================================================================
# Parse arguments
# ============================================================================
babs_parse_args "$@"

# Initialize run date (auto-generate or use env var)
babs_init_run_date

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
NIDM_ORIGIN="$(babs_nidm_origin "$DATASET_NAME" "$SITE_NAME")"

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
    "RUN_DATE=${RUN_DATE}" \
    "ZIP_VERSION=${ZIP_VERSION}"

babs_check_zip_version "$CONFIG_PATH" MRIQC_VERSION

babs_configure_session_selection "$CONFIG_PATH" "$PROCESSING_LEVEL" || exit 1

babs_configure_max_voxel_size "$CONFIG_PATH" "${MRIQC_MAX_VOXEL_SIZE:-}" "$MRIQC_VERSION" || exit 1
if [ -n "${MRIQC_MAX_VOXEL_SIZE:-}" ]; then
    echo "MRIQC max voxel size: ${MRIQC_MAX_VOXEL_SIZE} mm"
else
    echo "MRIQC max voxel size: none (every image is rated)"
fi

echo "BIDS origin URL: $BIDS_ORIGIN"
echo "NIDM origin URL: $NIDM_ORIGIN"

# ============================================================================
# Check NIDM directory
# ============================================================================
babs_check_nidm "$DATASET_NAME" "$SITE_NAME"

# ============================================================================
# Initialize BABS and submit
# ============================================================================
OUTPUT_DIR="$(babs_study_output_dir "$DATASET_NAME" "$SITE_NAME" "mriqc-nidm")"

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
