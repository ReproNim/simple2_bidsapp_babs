#!/usr/bin/env bash
set -euo pipefail

# Harvest a finished BABS run IN PLACE, inside the study tree.
#
# Usage: ./post_babs.sh <babs_project_dir>
# Example:
#   ./post_babs.sh \
#     /orcd/data/satra/002/datasets/simple2_datalad/study-ABIDE/site-Caltech/derivatives/babs-mriqc-nidm_aug27
#
# Under the BIDS-study layout the BABS project already lives beside the other
# derivatives, and every app now writes <output>/sub-<id>/... so each zip's top
# level IS the subject directory. Unzipping in place therefore produces exactly
# the delivered derivative:
#
#   derivatives/babs-<app>_<date>/
#   |-- dataset_description.json
#   |-- sub-<id>/{nidm.ttl, <app results>}
#   `-- nidm_merge.ttl
#
# There is no separate clone-and-copy step: the old version of this script
# cloned the output RIA into /orcd/scratch/bcs/002/sensein/simple2/<app>/... and
# derived that path by parsing a scratch-style project path. That parsing cannot
# match a study-tree path at all (it looks for a `<name>_babs` path component),
# so the script could not run on these projects.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `babs merge` must run under a BABS revision containing PennLINC/babs#369;
# v0.5.2 (the plain `babs` env) does not understand this project layout.
BABS_ENV="${BABS_ENV:-babs-369}"
eval "$(micromamba shell hook --shell bash)"
micromamba activate "$BABS_ENV"
echo "Using BABS: $(babs --version 2>&1 | tail -1) (env: ${BABS_ENV})"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <babs_project_dir>" >&2
  exit 1
fi

PROJECT_DIR="${1%/}"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "ERROR: not a directory: $PROJECT_DIR" >&2
  exit 1
fi
if [ ! -d "${PROJECT_DIR}/.babs" ]; then
  echo "ERROR: no .babs/ under $PROJECT_DIR — not a study-layout BABS project." >&2
  echo "  (Legacy projects kept the RIA stores at the top level; this script" >&2
  echo "   only supports the PR#369 study layout.)" >&2
  exit 1
fi
if [ ! -d "${PROJECT_DIR}/.babs/output_ria" ]; then
  echo "ERROR: no output RIA at ${PROJECT_DIR}/.babs/output_ria" >&2
  exit 1
fi

# Report what we are harvesting, from the study-tree path.
SITE="$(basename "$(dirname "$(dirname "$PROJECT_DIR")")")"   # site-<SITE>
DATASET="$(basename "$(dirname "$(dirname "$(dirname "$PROJECT_DIR")")")")"  # study-<NAME>
echo "Harvesting in place:"
echo "  PROJECT: $(basename "$PROJECT_DIR")"
echo "  DATASET: ${DATASET}"
echo "  SITE:    ${SITE}"
echo "  TARGET:  ${PROJECT_DIR}  (in place)"

# sanity checks
command -v datalad >/dev/null || { echo "ERROR: datalad not found"; exit 1; }
command -v unzip   >/dev/null || { echo "ERROR: unzip not found"; exit 1; }

# Pre-flight: `babs merge` finishes by fast-forwarding the project's master from
# the output RIA. If the project's local master has commits the output RIA does
# not (the classic cause: editing code/participant_job.sh after `babs init`),
# that ff-only update fails partway through -- after the job branches have
# already been merged and deleted, which is not safely re-runnable. Catch it
# before starting rather than halfway through.
cd "$PROJECT_DIR"
if git rev-parse --verify --quiet output/master >/dev/null 2>&1; then
  if [ -n "$(git rev-list output/master..master 2>/dev/null)" ]; then
    echo "ERROR: local master has commits not in output/master:" >&2
    git --no-pager log --oneline output/master..master >&2
    echo "  'babs merge' ends in an ff-only update of master and will fail." >&2
    echo "  Fix first (disjoint files make this conflict-free):" >&2
    echo "    git -C \"$PROJECT_DIR\" rebase output/master master" >&2
    echo "  Then re-run this script." >&2
    exit 1
  fi
fi

# Merge the per-job result branches (continue if there is nothing new to merge)
if ! babs merge "$PROJECT_DIR" 2>&1; then
  echo "Note: babs merge had no new jobs to merge (already merged or none finished)"
fi
echo "after babs merge"

cd "$PROJECT_DIR"

# Pull down the result zips' contents. The zips sit at the project root as
# sub-<id>_<foldername>-<version>.zip git-annex keys.
shopt -s nullglob
zips=(sub-*.zip)
if ((${#zips[@]})); then
  echo "datalad get on ${#zips[@]} zip(s)…"
  datalad get "${zips[@]}"
else
  echo "No sub-*.zip found at the project root — nothing to harvest."
  echo "  (Have the jobs finished? Check: babs status \"$PROJECT_DIR\")"
  shopt -u nullglob
  exit 0
fi

for z in "${zips[@]}"; do
  echo "unzipping $z"
  # -n: never clobber. Each zip's top level is its own sub-<id>/, so distinct
  # subjects cannot collide and nothing is silently dropped.
  unzip -n "$z"
done
shopt -u nullglob
echo "after unzip"

# Merge the per-subject NIDM graphs into one study-level file. The merge script
# skips sourcedata/ and merge_ds/, so the INPUT NIDM this run appended to is not
# folded back in.
MERGE_SCRIPT="${SCRIPT_DIR}/merge_ttl_files.py"
if [ -f "$MERGE_SCRIPT" ]; then
  echo "Running TTL merge..."
  python "$MERGE_SCRIPT" "$PROJECT_DIR"
else
  echo "WARNING: merge_ttl_files.py not found at $MERGE_SCRIPT"
fi

echo "Done."
