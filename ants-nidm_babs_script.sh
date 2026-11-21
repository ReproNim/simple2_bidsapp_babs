#!/bin/bash
# ANTs-NIDM BABS Script
# Usage: ./ants-nidm_babs_script.sh <site_name> <dataset_name> [processing_level]
#
# Arguments:
#   site_name         - Site identifier (e.g., Caltech, Brown)
#   dataset_name      - Dataset identifier (e.g., study-ABIDE, study-ADHD200)
#   processing_level  - Optional: "subject" or "session" (default: subject)
#
# Examples:
#   Single-session dataset:  ./ants-nidm_babs_script.sh Caltech study-ABIDE
#   Multi-session dataset:   ./ants-nidm_babs_script.sh Brown study-ADHD200 session
#
# Optional environment variable:
#   RUN_DATE=YYMMDD          - Use specific date instead of auto-generated
#   ANTS_VERSION=X.Y.Z       - Run ants-nidm_bidsapp-X.Y.Z.sif (default 0.2.3);
#                              also sets the container name and zip version
#   BABS_OUTPUT_DIR=<path>   - Place the project at an explicit path, which
#                              is required when a project already exists for
#                              this site (the wrapper stops otherwise)

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the common functions library
source "${SCRIPT_DIR}/babs_common.sh"

# ============================================================================
# ANTs-NIDM-specific configuration
# ============================================================================
APP_NAME="ants-nidm"
SCRATCH_DIR="$SCRATCH_DIR_ANTS"
CONTAINER_DS_NAME="ants-nidm_bidsapp-container"
# ants-nidm 0.2.0: registration on FireANTs (GPU), joint-fusion and BVOL fixes,
# per-method NIDM label names, T1w choice when a session has several.
# 0.2.1: atlas files readable by every account (the 0.2.0 SIF works only for
# the account that built it), --skip-ants records the T1w the existing
# segmentation used.
# 0.2.2: a NIDM input that was never fetched (a git-annex symlink with no
# content) fails the job, and a subject with no NIDM input is warned about;
# the image's org.opencontainers.image.version label is the app version.
# 0.2.3: PyNIDM 5.0.0 inside the image; give it the nidm_5.0.0 inputs. Before
# any GPU work, the job fails when the input NIDM holds other subjects but not
# this one, or several nodes for this subject that cannot be resolved; subject
# ids are matched without the sub- prefix and leading zeros. An explicit
# --nidm-input-dir that is missing, not searchable or empty is a usage error
# instead of a warning. nidm.ttl links only the acquisition of the segmented
# T1w. A label id outside the selected label protocol fails the job after
# segmentation. --method quick now initialises from the plain images, so its
# labels can differ from 0.2.2: on most subjects within run-to-run variation,
# but individual labels can change on some subjects. The fusion code is
# unchanged; fusion segmentations differ from 0.2.2 only by FireANTs'
# run-to-run variation.
# Build it from the ants-nidm_bidsapp v0.2.3 tag with scripts/build_sif.sbatch
# under this name.
# Older images reproduce older runs: the Caltech babs-ants-nidm-0-2-0
# derivative came from ants-nidm_bidsapp-0.2.0.sif (ANTS_VERSION=0.2.0), and
# the 0.1.0 derivative it replaced from ants-nidm_bidsapp-0.1.0.sif
# (ANTS_VERSION=0.1.0).
# One variable names the image, the container and the zip version, so a run
# cannot label one version's outputs with another's number.
ANTS_VERSION="${ANTS_VERSION:-0.2.3}"
babs_resolve_version ANTS_VERSION "$ANTS_VERSION"
babs_require_nidm_match ANTS_VERSION "$ANTS_VERSION" 0.2.3
CONTAINER_NAME="ants-nidm-bidsapp-${ZIP_VERSION}"
SIF_FILENAME="ants-nidm_bidsapp-${ANTS_VERSION}.sif"
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
RUN_DIR="${SCRATCH_DIR}/${DATASET_NAME}_site-${SITE_NAME}_${RUN_DATE}"
COMPUTE_DIR="${SCRATCH_DIR_COMPUTE}/ants-nidm_compute_${RUN_DATE}"

# Stop before any image is copied if this site already has a project.
OUTPUT_DIR="$(babs_study_output_dir "$DATASET_NAME" "$SITE_NAME" "ants-nidm")"
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

# Verify BIDS dataset exists
if [ ! -d "$BIDS_ORIGIN" ]; then
    echo "ERROR: BIDS dataset not found at $BIDS_ORIGIN"
    exit 1
fi

CONFIG_PATH="${RUN_DIR}/config_ants-nidm.yaml"

babs_prepare_yaml_config \
    "${SCRIPT_DIR}/config_ants-nidm.yaml" \
    "$CONFIG_PATH" \
    "BIDS_ORIGIN=${BIDS_ORIGIN}" \
    "NIDM_ORIGIN=${NIDM_ORIGIN}" \
    "COMPUTE_SPACE=${COMPUTE_DIR}" \
    "RUN_DATE=${RUN_DATE}" \
    "ZIP_VERSION=${ZIP_VERSION}"

babs_check_zip_version "$CONFIG_PATH" ANTS_VERSION

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
