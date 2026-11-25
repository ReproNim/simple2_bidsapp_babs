#!/bin/bash
# Write the BIDS dataset_description.json and .bidsignore at the root of a
# harvested BABS derivative project.
#
# Usage: ./babs_dataset_description.sh [--force] [--source-url PATH=URL ...] <project_dir>
#
#   project_dir   the BABS project root, <site>/derivatives/babs-<app>[-<ver>]
#   --force       replace a dataset_description.json or .bidsignore that
#                 already exists with different content (default: stop and
#                 show the difference)
#   --source-url PATH=URL
#                 record URL instead of the .gitmodules URL for the input
#                 subdataset at PATH (e.g. sourcedata/BIDS), for when the
#                 input is published at a different address; repeatable
#
# Run it once per project, after the study's harvest script (code/post_babs.sh)
# and with the babs environment active (it needs babs, datalad, git-annex, jq
# and apptainer on PATH). It reads the app and its version from the container
# registered under containers/ and checks them against the image's labels;
# the input URLs come from .gitmodules (or --source-url) and their commits
# from HEAD; the BABS version is the babs on PATH. It stops when a piece is
# missing.
#
# Supported: projects built from images that carry org.opencontainers.image.*
# labels (the current releases: ants-nidm 0.2.3, freesurfer-nidm 0.1.4,
# mriqc-nidm 0.1.5). Projects from older images are refused.
#
# The files are written with `datalad run`, so the command is recorded in the
# commit. When the project is a subdataset of a site dataset, the site's
# pointer to it is updated, as post_babs.sh does.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# babs_common.sh sources ./.env from the current directory; this script needs
# none of it, so source it from / and do not run a .env of the caller's cwd.
CALLER_PWD="$PWD"
cd /
source "${SCRIPT_DIR}/babs_common.sh"
cd "$CALLER_PWD"

# The BIDS specification release this description claims to follow
# (https://github.com/bids-standard/bids-specification/releases).
BIDS_VERSION="1.11.2"
BABS_CODE_URL="https://github.com/PennLINC/babs"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    sed -n '2,/^set -Eeuo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

# BIDS does not define the per-subject NIDM bundles, FreeSurfer's own tree,
# the nested MRIQC dataset, the result zips or the BABS bookkeeping, so the
# validator is told to skip them. The outputs are not moved into BIDS layout.
BIDSIGNORE='# Not BIDS: each subject holds the app'"'"'s own bundle (nidm.ttl, *_cde.ttl,
# stats, the FreeSurfer tree, the nested MRIQC dataset).
/sub-*
# BABS bookkeeping and the dataset'"'"'s inputs.
/code
/containers
/logs
/sourcedata
# Result zips, content dropped after the harvest.
/*.zip
# Created empty by BABS.
/CHANGELOG.md'

# The first GeneratedBy Name must be part of the derivative directory name, so
# it is the app name; the registered container is named <app>-bidsapp-X-Y-Z.
# Each app's source repository is also what its image's source label names.
app_code_url() {
    case "$1" in
        ants-nidm) echo "https://github.com/ReproNim/ants-nidm_bidsapp" ;;
        freesurfer-nidm) echo "https://github.com/ReproNim/freesurfer-nidm_bidsapp" ;;
        mriqc-nidm) echo "https://github.com/ReproNim/mriqc-nidm_bidsapp" ;;
        *) return 1 ;;
    esac
}

# Git refuses a repository owned by another user, and 'git status' then prints
# nothing on stdout, which reads as a clean tree. Check it first.
require_git_access() {   # $1 = repo path, $2 = label
    local out
    if out=$(git -C "$1" rev-parse --git-dir 2>&1); then
        return 0
    fi
    echo "ERROR: git cannot operate on the $2 at $1:" >&2
    sed 's/^/    /' <<< "$out" >&2
    if grep -qi 'dubious ownership' <<< "$out"; then
        echo "  This is git's ownership guard, not a corrupt repo. Allow it, then rerun:" >&2
        echo "    git config --global --add safe.directory '$1'" >&2
    fi
    exit 1
}

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
FORCE=no
PROJECT_ARG=""
declare -A SOURCE_URL_OVERRIDE=()
while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=yes ;;
        --source-url)
            [ $# -ge 2 ] || { usage >&2; die "--source-url needs PATH=URL"; }
            [[ "$2" == sourcedata/*=?* ]] || { usage >&2; die "--source-url takes sourcedata/<name>=<URL>, got '$2'"; }
            src_path="${2%%=*}"; src_url="${2#*=}"
            [ -z "${SOURCE_URL_OVERRIDE[$src_path]+x}" ] || die "--source-url given twice for ${src_path}"
            [[ "$src_url" != =* ]] || die "--source-url: the URL for ${src_path} starts with '=' (write PATH=URL with one '=')"
            [[ ! "$src_url" =~ [[:space:][:cntrl:]] ]] || die "--source-url: the URL for ${src_path} holds whitespace or a control character"
            SOURCE_URL_OVERRIDE["$src_path"]="$src_url"
            shift ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option $1" ;;
        *)
            [ -z "$PROJECT_ARG" ] || { usage >&2; die "one project directory only"; }
            PROJECT_ARG="$1" ;;
    esac
    shift
done
[ -n "$PROJECT_ARG" ] || { usage >&2; exit 1; }
[ -d "$PROJECT_ARG" ] || die "project dir not found: $PROJECT_ARG"

# The directory's own name is published, so keep the name it was given (a
# symlink is not resolved); the parents are read the same way.
PROJECT_DIR=$(cd "$PROJECT_ARG" && pwd -L)
PROJECT_NAME=$(basename "$PROJECT_DIR")
SITE_DIR=$(cd "$PROJECT_DIR/../.." 2>/dev/null && pwd -L || true)

for tool in babs datalad jq apptainer; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found on PATH. Activate the babs environment (micromamba activate ${BABS_ENV}) and load apptainer."
done
# The project sets filter.annex.process: git commands shell out to git-annex
# and damage the working tree without it.
command -v git-annex >/dev/null 2>&1 || die "git-annex not found on PATH. These datasets set filter.annex.process; without git-annex, git can empty tracked files. Activate the babs environment."

require_git_access "$PROJECT_DIR" "project"
if [ -n "$SITE_DIR" ] && [ -d "$SITE_DIR/.git" ]; then
    require_git_access "$SITE_DIR" "site dataset"
fi

cd "$PROJECT_DIR"

# ----------------------------------------------------------------------------
# Refuse a project that was not harvested, or that has unsaved changes
# ----------------------------------------------------------------------------
if [ -z "$(find . -maxdepth 1 -type d -name 'sub-*' -print -quit)" ]; then
    die "no sub-*/ directory in ${PROJECT_DIR}: the project is not harvested. Run the study's code/post_babs.sh on it first."
fi
if ! status_out=$(git status --porcelain --untracked-files=no); then
    die "'git status' failed in ${PROJECT_DIR} (git's own error is above), so it cannot be checked for unsaved changes."
fi
if [ -n "$status_out" ]; then
    echo "ERROR: uncommitted changes in ${PROJECT_DIR} -- save or stash first:" >&2
    git status --short >&2
    exit 1
fi

# ----------------------------------------------------------------------------
# What the project records
# ----------------------------------------------------------------------------
# The app and its version: the one container registered in containers/.
CONTAINER_CONFIG="containers/.datalad/config"
[ -f "$CONTAINER_CONFIG" ] || die "${PROJECT_DIR}/${CONTAINER_CONFIG} not found: the project has no registered container (is containers/ checked out?)."
mapfile -t container_keys < <(git config -f "$CONTAINER_CONFIG" --name-only --get-regexp '^datalad\.containers\..+\.image$')
[ "${#container_keys[@]}" -eq 1 ] || die "expected one container in ${CONTAINER_CONFIG}, found ${#container_keys[@]}."
CONTAINER_NAME="${container_keys[0]#datalad.containers.}"
CONTAINER_NAME="${CONTAINER_NAME%.image}"
IMAGE_REL=$(git config -f "$CONTAINER_CONFIG" "${container_keys[0]}")
if [[ ! "$CONTAINER_NAME" =~ ^(.+)-bidsapp-([0-9]+)-([0-9]+)-([0-9]+)$ ]]; then
    die "the registered container '${CONTAINER_NAME}' is not named <app>-bidsapp-X-Y-Z."
fi
APP_NAME="${BASH_REMATCH[1]}"
APP_VERSION="${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
CODE_URL=$(app_code_url "$APP_NAME") || die "the registered container is for '${APP_NAME}', which is not one of ants-nidm, freesurfer-nidm, mriqc-nidm."

# BIDS: the first GeneratedBy Name must be a substring of the directory name.
if [[ "$PROJECT_NAME" != *"$APP_NAME"* ]]; then
    die "the project directory is named '${PROJECT_NAME}', which does not contain the app name '${APP_NAME}'. BIDS requires the first GeneratedBy Name to be part of the derivative directory name; name the directory babs-${APP_NAME}-${APP_VERSION//./-}."
fi

# The image: read its labels and check them against the container's name.
IMAGE_PATH="containers/${IMAGE_REL}"
[ -e "$IMAGE_PATH" ] || die "the container image ${PROJECT_DIR}/${IMAGE_PATH} has no content here. Fetch it (datalad get ${IMAGE_PATH}); its labels are recorded in the description."
LABEL_SOURCE=$(babs_image_label "$IMAGE_PATH" org.opencontainers.image.source) || die "apptainer cannot read ${IMAGE_PATH}."
LABEL_VERSION=$(babs_image_label "$IMAGE_PATH" org.opencontainers.image.version) || die "apptainer cannot read ${IMAGE_PATH}."
LABEL_REVISION=$(babs_image_label "$IMAGE_PATH" org.opencontainers.image.revision) || die "apptainer cannot read ${IMAGE_PATH}."
if [ -z "$LABEL_SOURCE" ]; then
    die "${IMAGE_PATH} has no org.opencontainers.image.source label, so it cannot be tied to ${CODE_URL}. Images built before the PyNIDM 5 releases (ants-nidm 0.2.3, freesurfer-nidm 0.1.4, mriqc-nidm 0.1.5) carry no such label, and projects built from them are not supported by this script."
fi
# Compare the whole repository URL, not its last part: another owner's fork
# of the same repository name must not pass.
normalize_url() {
    local u="${1,,}"
    u="${u%/}"; u="${u%.git}"; u="${u%/}"
    u="${u#http://}"; u="${u#https://}"
    echo "$u"
}
if [ "$(normalize_url "$LABEL_SOURCE")" != "$(normalize_url "$CODE_URL")" ]; then
    die "${IMAGE_PATH} was built from ${LABEL_SOURCE}, but the container is named for ${APP_NAME} (${CODE_URL})."
fi
LABEL_SOURCE="${LABEL_SOURCE%/}"
LABEL_SOURCE="${LABEL_SOURCE%.git}"
[ "$LABEL_VERSION" = "$APP_VERSION" ] || die "${IMAGE_PATH} is labelled version '${LABEL_VERSION}', but the container is named for ${APP_VERSION}."
# The wrappers register ${repo}-${version}.sif under this container name.
IMAGE_TAG="${CODE_URL##*/}-${APP_VERSION}.sif"
if [ -n "$LABEL_REVISION" ]; then
    APP_DESCRIPTION="Image ${IMAGE_TAG} built from ${LABEL_SOURCE} at revision ${LABEL_REVISION}."
else
    APP_DESCRIPTION="Image ${IMAGE_TAG} built from ${LABEL_SOURCE}."
fi

# BABS: the project does not record the version that made it, so this is the
# babs that is running now. The entry says so in its Description: a bare
# Version would read as the version that ran the jobs.
babs_rc=0
babs_out=$(babs --version 2>&1) || babs_rc=$?
[ "$babs_rc" -eq 0 ] || die "'babs --version' failed (exit ${babs_rc}): ${babs_out:-no output}"
BABS_VERSION=$(tail -1 <<< "$babs_out" | sed -E 's/^babs +//; s/^v//')
BABS_DESCRIPTION="babs version installed when this description was written; the jobs' version is in the project history."
[[ "$BABS_VERSION" =~ ^[0-9][0-9A-Za-z.+_-]*$ ]] || die "could not read a version from 'babs --version' (got '${BABS_VERSION}')."

# Inputs: one entry per subdataset under sourcedata/, at the commit the
# project records for it.
SOURCES='[]'
n_sources=0
while read -r key sub_path; do
    [[ "$sub_path" == sourcedata/* ]] || continue
    sub_name="${key#submodule.}"
    sub_name="${sub_name%.path}"
    sub_url=$(git config -f .gitmodules "submodule.${sub_name}.url") || die ".gitmodules records no url for ${sub_path}."
    if [ -n "${SOURCE_URL_OVERRIDE[$sub_path]+x}" ]; then
        sub_url="${SOURCE_URL_OVERRIDE[$sub_path]}"
        unset 'SOURCE_URL_OVERRIDE[$sub_path]'
    fi
    sub_commit=$(git ls-tree HEAD -- "$sub_path" | awk '$1 == "160000" {print $3}')
    [ -n "$sub_commit" ] || die "${sub_path} is in .gitmodules but HEAD records no commit for it."
    SOURCES=$(jq -c --argjson cur "$SOURCES" --arg u "$sub_url" --arg v "$sub_commit" -n '$cur + [{URL: $u, Version: $v}]')
    n_sources=$((n_sources + 1))
done < <(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' | sort -k2)
[ "$n_sources" -gt 0 ] || die "no input subdataset under sourcedata/ in ${PROJECT_DIR}/.gitmodules."
[ "${#SOURCE_URL_OVERRIDE[@]}" -eq 0 ] || die "--source-url names no input subdataset of this project: ${!SOURCE_URL_OVERRIDE[*]}"

# Name: "<study> <site>: <app> <version> derivatives" under
# <study-X>/<site-Y>/derivatives, the bare "<app> <version> derivatives" elsewhere.
DS_NAME="${APP_NAME} ${APP_VERSION} derivatives"
if [ -n "$SITE_DIR" ] && [ "$(basename "$(dirname "$PROJECT_DIR")")" = derivatives ]; then
    site_label=$(basename "$SITE_DIR")
    study_label=$(basename "$(dirname "$SITE_DIR")")
    if [[ "$site_label" == site-* && "$study_label" == study-* ]]; then
        DS_NAME="${study_label#study-} ${site_label#site-}: ${DS_NAME}"
    fi
fi

DESCRIPTION_JSON=$(jq -n \
    --arg name "$DS_NAME" --arg bids "$BIDS_VERSION" \
    --arg app "$APP_NAME" --arg appver "$APP_VERSION" --arg desc "$APP_DESCRIPTION" \
    --arg url "$CODE_URL" --arg tag "$IMAGE_TAG" \
    --arg babs "$BABS_VERSION" --arg babsdesc "$BABS_DESCRIPTION" --arg babsurl "$BABS_CODE_URL" \
    --argjson sources "$SOURCES" '{
        Name: $name,
        BIDSVersion: $bids,
        DatasetType: "derivative",
        GeneratedBy: [
            {
                Name: $app,
                Version: $appver,
                Description: $desc,
                CodeURL: $url,
                Container: {Type: "apptainer", Tag: $tag}
            },
            {Name: "BABS", Version: $babs, Description: $babsdesc, CodeURL: $babsurl}
        ],
        SourceDatasets: $sources
    }')

# ----------------------------------------------------------------------------
# Compare with what is there, then write
# ----------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
printf '%s\n' "$DESCRIPTION_JSON" > "$WORK_DIR/dataset_description.json"
printf '%s\n' "$BIDSIGNORE" > "$WORK_DIR/.bidsignore"

# "Up to date" means committed: compare with HEAD, not with the working tree.
# An identical file that is untracked (a `datalad run` interrupted before its
# save, or one made by hand) is not part of the project's history, and the
# dirty check above does not see untracked files.
need_write=no
conflict=no
for f in dataset_description.json .bidsignore; do
    if git cat-file -e "HEAD:${f}" 2>/dev/null; then
        git show "HEAD:${f}" > "$WORK_DIR/head_${f}"
        if ! cmp -s "$WORK_DIR/head_${f}" "$WORK_DIR/$f"; then
            need_write=yes
            conflict=yes
            echo "${f} is committed with different content (- committed, + new):" >&2
            diff -u --label "HEAD/${f}" --label "new/${f}" "$WORK_DIR/head_${f}" "$WORK_DIR/$f" >&2 || true
        fi
    else
        need_write=yes
        if [ -e "$f" ] && [ "$FORCE" != yes ]; then
            die "${f} exists in ${PROJECT_DIR} but is not committed (untracked, for example after an interrupted datalad run), so it is not part of the project's history. Remove it and rerun, or rerun with --force to write and commit it."
        fi
    fi
done
if [ "$conflict" = yes ] && [ "$FORCE" != yes ]; then
    die "not overwriting. Rerun with --force to replace the file(s) shown above."
fi

if [ "$need_write" = no ]; then
    echo "dataset_description.json and .bidsignore are up to date."
else
    # The files must go into git, not the annex: the comparison above reads
    # them from git, and a symlink into the annex would read as "different"
    # on every rerun. text2git (BABS_TEXT2GIT, on by default) sets this rule.
    for f in dataset_description.json .bidsignore; do
        rule=$(git check-attr annex.largefiles -- "$f")
        rule="${rule##*: }"
        if [ "$rule" = unspecified ] || [ "$rule" = anything ]; then
            die "${PROJECT_DIR} does not keep text files in git (no annex.largefiles rule covers ${f}), so ${f} would be annexed. The project was created without text2git (BABS_TEXT2GIT=0?). Add the rule and commit it, e.g. 'cd ${PROJECT_DIR} && datalad run-procedure cfg_text2git', then rerun."
        fi
    done
    # Other untracked files would make datalad run refuse after the leftovers
    # were deleted, so look before deleting anything.
    others=$(git status --porcelain | grep -v -x -e '?? dataset_description.json' -e '?? .bidsignore' || true)
    if [ -n "$others" ]; then
        echo "ERROR: untracked or changed files besides the two to write in ${PROJECT_DIR}; datalad run needs a clean dataset. Commit or remove them first:" >&2
        sed 's/^/    /' <<< "$others" >&2
        exit 1
    fi
    # Under --force, files that exist without being committed are rewritten:
    # datalad run needs a clean dataset, so remove them first.
    for f in dataset_description.json .bidsignore; do
        if ! git cat-file -e "HEAD:${f}" 2>/dev/null; then rm -f -- "$f"; fi
    done
    # datalad run treats {...} in the command as a placeholder; {{ and }} are
    # its escapes for literal braces.
    json_arg="${DESCRIPTION_JSON//\{/\{\{}"
    json_arg="${json_arg//\}/\}\}}"
    ignore_arg="${BIDSIGNORE//\{/\{\{}"
    ignore_arg="${ignore_arg//\}/\}\}}"
    # From the physical root: datalad records the run's directory relative
    # to the dataset, which through a symlink would be a "../../.." path.
    cd "$(pwd -P)"
    datalad run -d . \
        -m "Write the BIDS dataset_description.json and .bidsignore" \
        --output dataset_description.json --output .bidsignore \
        bash -c 'printf "%s\n" "$1" > dataset_description.json; printf "%s\n" "$2" > .bidsignore' \
        write-dataset-description "$json_arg" "$ignore_arg"
    for f in dataset_description.json .bidsignore; do
        cmp -s "$f" "$WORK_DIR/$f" || die "${f} differs from the intended content after datalad run."
    done
    echo "wrote dataset_description.json and .bidsignore"
fi

# ----------------------------------------------------------------------------
# Update the site dataset's pointer to this project, as post_babs.sh does:
# from inside the site dataset (datalad resolves the path against the working
# directory, and from anywhere else a pointer-only save silently does nothing).
# ----------------------------------------------------------------------------
if [ -n "$SITE_DIR" ] && [ -d "$SITE_DIR/.git" ]; then
    SUB_RELPATH="${PROJECT_DIR#"$SITE_DIR"/}"
    cd "$SITE_DIR"
    datalad save -d "$SITE_DIR" -m "Update ${SUB_RELPATH} pointer after dataset_description" -- "$SUB_RELPATH"
else
    echo "no site dataset two levels up: no pointer to update."
fi
