#!/usr/bin/env bash
set -euo pipefail

# Usage: ./post_babs.sh <babs_run_dir>
# Example:
#   ./post_babs.sh \
#     /orcd/scratch/bcs/001/yibei/simple2/mriqc_bidsapp_babs/study_abide_1223/mriqc_bidsapp_Caltech_1223
#   Output will be automatically created at:
#     /orcd/scratch/bcs/002/sensein/simple2/mriqc_bidsapp/study_abide/Caltech

# Capture script directory early, before any cd commands
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

eval "$(micromamba shell hook --shell bash)"
micromamba activate babs

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <babs_run_dir>" >&2
  exit 1
fi

BABS_RUN_DIR="${1%/}"        # e.g., .../mriqc_bidsapp_babs/study_abide_1223/mriqc_bidsapp_Caltech_1223

# Parse the input path to extract bidsapp, dataset, and site
# Pattern: .../simple2/<bidsapp>_babs/<dataset>_MMDD/<bidsapp>_<site>_MMDD

# Extract components from path
IFS='/' read -ra PATH_PARTS <<< "$BABS_RUN_DIR"

# Find bidsapp (folder ending in _babs)
for part in "${PATH_PARTS[@]}"; do
  if [[ "$part" =~ ^(.+)_babs$ ]]; then
    BIDSAPP="${BASH_REMATCH[1]}"
    break
  fi
done

# Find dataset (folder matching study_*_[0-9]+)
for part in "${PATH_PARTS[@]}"; do
  if [[ "$part" =~ ^(study_[^_]+)_[0-9]+$ ]]; then
    DATASET="${BASH_REMATCH[1]}"
    break
  fi
done

# Extract site from the last component
# Pattern: <bidsapp>_<site>_MMDD -> extract <site>
LAST_COMPONENT="${PATH_PARTS[-1]}"
if [[ "$LAST_COMPONENT" =~ ^${BIDSAPP}_(.+)_[0-9]+$ ]]; then
  SITE="${BASH_REMATCH[1]}"
else
  echo "ERROR: Could not extract site from: $LAST_COMPONENT" >&2
  exit 1
fi

# Construct output path
OUTPUT_BASE="/orcd/scratch/bcs/002/sensein/simple2"
TARGET_DIR="${OUTPUT_BASE}/${BIDSAPP}/${DATASET}/${SITE}"

echo "Parsed components:"
echo "  BIDSAPP: $BIDSAPP"
echo "  DATASET: $DATASET"
echo "  SITE: $SITE"
echo "  TARGET_DIR: $TARGET_DIR"

# RIA store lives under .../output_ria#~data
RIA_URL="ria+file://${BABS_RUN_DIR}/output_ria#~data"

# sanity checks
command -v datalad >/dev/null || { echo "ERROR: datalad not found"; exit 1; }
command -v unzip   >/dev/null || { echo "ERROR: unzip not found"; exit 1; }

# Run babs merge (continue if no jobs to merge)
if ! babs merge ${BABS_RUN_DIR} 2>&1; then
  echo "Note: babs merge had no new jobs to merge (already merged or none finished)"
fi
echo "after babs merge"
mkdir -p "$(dirname "$TARGET_DIR")"

# Clone if needed, or update if already exists
if [ ! -d "$TARGET_DIR/.git" ] && [ ! -d "$TARGET_DIR/.datalad" ]; then
  echo "Cloning from: $RIA_URL"
  datalad clone "$RIA_URL" "$TARGET_DIR"
else
  echo "Dataset already exists at $TARGET_DIR — updating..."
  cd "$TARGET_DIR"
  datalad update --merge
fi

cd "$TARGET_DIR"

# Get top-level sub* (dirs/files) if they exist; skip otherwise
shopt -s nullglob
subs=(sub-*)
if ((${#subs[@]})); then
  echo "datalad get on ${#subs[@]} sub* item(s)…"
  datalad get "${subs[@]}"
else
  echo "No top-level sub* entries found — skipping datalad get sub-*"
fi
shopt -u nullglob
echo "after datalad get"

for z in sub-*.zip; do
  [ -e "$z" ] || continue
  echo "unzipping $z"
  unzip -n "$z"
done

# Merge NIDM TTL files (script searches recursively for all patterns)
MERGE_SCRIPT="${SCRIPT_DIR}/merge_ttl_files.py"
if [ -f "$MERGE_SCRIPT" ]; then
  echo "Running TTL merge..."
  python "$MERGE_SCRIPT" "${TARGET_DIR}"
else
  echo "WARNING: merge_ttl_files.py not found at $MERGE_SCRIPT"
fi

echo "Done."
