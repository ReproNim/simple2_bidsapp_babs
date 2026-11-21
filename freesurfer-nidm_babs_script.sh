#!/bin/bash
# FreeSurfer-NIDM BABS Script
# Usage: ./freesurfer-nidm_babs_script.sh <site_name> <dataset_name> [processing_level]
#
# Arguments:
#   site_name         - Site identifier (e.g., Caltech, Brown)
#   dataset_name      - Dataset identifier (e.g., study-ABIDE, study-ADHD200)
#   processing_level  - Optional: "subject" or "session" (default: subject)
#
# Examples:
#   Single-session dataset:  ./freesurfer-nidm_babs_script.sh Caltech study-ABIDE
#   Multi-session dataset:   ./freesurfer-nidm_babs_script.sh Brown study-ADHD200 session
#
# Optional environment variable:
#   RUN_DATE=YYMMDD - Use specific date instead of auto-generated
#   FS_VERSION=X.Y.Z - Run freesurfer-nidm_bidsapp-X.Y.Z.sif (default 0.1.4);
#                         also sets the container name and zip version

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
# 0.1.3: the FreeSurfer measures in nidm.ttl belong to the input NIDM's subject
# and, when the app finds the T1w images, to the T1w recon-all used.
# 0.1.0-0.1.2 attached them to a separate agent named "freesurfer", so a query
# joining measures to subjects misses those sites. Before pooling them with
# 0.1.3 output, regenerate their NIDM by running the 0.1.3 image directly (not
# through this wrapper, whose jobs start without the recon-all output) with
# --skip-freesurfer, the site's BIDS dataset (T1w content fetched) as input,
# --nidm-input-dir set to the site's input NIDM, and a copy of each subject's
# harvested freesurfer/ directory at <output_dir>/sub-<id>[/ses-<x>]/freesurfer.
# 0.1.4: PyNIDM 5.0.0 inside the image; the converter finds the subject in
# input NIDM written by PyNIDM 5, matching ids without the sub- prefix and
# leading zeros. Before recon-all, the job fails when the input NIDM holds
# other subjects but not this one, has several nodes for this subject that
# cannot be told apart, has no nidm:Project, cannot be parsed, or was never
# fetched. A missing input NIDM is still only a warning. An explicit
# --nidm-input-dir that is missing or empty is a usage error. nidm.ttl is
# written only when the conversion succeeds, so a failed conversion leaves an
# earlier nidm.ttl in place. Build it from the freesurfer-nidm_bidsapp v0.1.4
# tag.
# One variable names the image, the container and the zip version, so a run
# cannot label one version's outputs with another's number.
FS_VERSION="${FS_VERSION:-0.1.4}"
babs_resolve_version FS_VERSION "$FS_VERSION"
CONTAINER_NAME="freesurfer-nidm-bidsapp-${ZIP_VERSION}"
SIF_FILENAME="freesurfer-nidm_bidsapp-${FS_VERSION}.sif"
SIF_ALT_PATHS=()   # searched after BASE_DIR; add more via SIF_SEARCH_DIRS in .env

# ============================================================================
# Parse arguments
# ============================================================================
babs_parse_args "$@"

# Initialize run date (auto-generate or use env var)
babs_init_run_date

# Validate FreeSurfer license (fail fast before submitting jobs)
if [ -z "${FS_LICENSE:-}" ]; then
    echo "ERROR: FS_LICENSE is not set. Add 'FS_LICENSE=/path/to/license.txt' to .env" >&2
    exit 1
fi
if [ ! -f "$FS_LICENSE" ]; then
    echo "ERROR: FreeSurfer license file not found at FS_LICENSE=$FS_LICENSE" >&2
    exit 1
fi

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
RUN_DIR="${SCRATCH_DIR}/${DATASET_NAME}_site-${SITE_NAME}_${RUN_DATE}"
COMPUTE_DIR="${SCRATCH_DIR_COMPUTE}/freesurfer-nidm_compute_${RUN_DATE}"

# Stop before any image is copied if this site already has a project.
OUTPUT_DIR="$(babs_study_output_dir "$DATASET_NAME" "$SITE_NAME" "freesurfer-nidm")"
babs_check_no_project "$OUTPUT_DIR"

mkdir -p "$RUN_DIR" "$COMPUTE_DIR" || exit 1
cd "$RUN_DIR" || exit 1
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

CONFIG_PATH="${RUN_DIR}/config_freesurfer-nidm.yaml"

babs_prepare_yaml_config \
    "${SCRIPT_DIR}/config_freesurfer-nidm.yaml" \
    "$CONFIG_PATH" \
    "BIDS_ORIGIN=${BIDS_ORIGIN}" \
    "NIDM_ORIGIN=${NIDM_ORIGIN}" \
    "COMPUTE_SPACE=${COMPUTE_DIR}" \
    "RUN_DATE=${RUN_DATE}" \
    "FS_LICENSE=${FS_LICENSE}" \
    "ZIP_VERSION=${ZIP_VERSION}"

babs_check_zip_version "$CONFIG_PATH" FS_VERSION

babs_configure_session_selection "$CONFIG_PATH" "$PROCESSING_LEVEL" || exit 1

echo "BIDS origin URL: $BIDS_ORIGIN"
echo "NIDM origin URL: $NIDM_ORIGIN"

# ============================================================================
# Check NIDM directory
# ============================================================================
babs_check_nidm "$DATASET_NAME" "$SITE_NAME"

# ============================================================================
# Initialize BABS and submit
# ============================================================================
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
