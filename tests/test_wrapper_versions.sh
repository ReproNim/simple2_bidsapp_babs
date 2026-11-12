#!/usr/bin/env bash
# Each wrapper takes one version (ANTS_VERSION, FS_VERSION, MRIQC_VERSION) and
# must use it for the image file, the container name and the zip suffix alike,
# so outputs are labelled with the version that produced them.
#
# This runs the three real wrappers with stand-ins for babs, datalad and
# apptainer on PATH and checks what the wrappers handed them. Nothing is
# submitted and no real image or dataset is read.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

STUBS="$TEST_TMPDIR/bin"
FAKE_HOME="$TEST_TMPDIR/home"
mkdir -p "$STUBS" "$FAKE_HOME"

# babs: report a version that passes the layout check, and record what `init`
# was given. `init` creates the project directory, as the wrapper enters it.
cat > "$STUBS/babs" <<'EOF'
#!/bin/bash
case "${1:-}" in
    --version) echo "babs v0.5.5.dev32+gea5d6f023" ;;
    init)
        project="${@: -1}"
        mkdir -p "$project"
        name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --container_name) name="$2" ;;
                --container_config) cp "$2" "$STUB_DIR/config.yaml" ;;
            esac
            shift
        done
        echo "babs-init container_name=${name}" >> "$STUB_DIR/calls.log" ;;
esac
exit 0
EOF

# datalad: `create` makes the container dataset directory; `containers-add`
# records which image file was registered (its content names it) and as what.
cat > "$STUBS/datalad" <<'EOF'
#!/bin/bash
case "${1:-}" in
    create)
        dataset="${@: -1}"
        mkdir -p "$dataset/.datalad"
        : > "$dataset/.datalad/config" ;;
    containers-add)
        url=""
        name="${@: -1}"
        while [ $# -gt 0 ]; do
            [ "$1" = "--url" ] && url="$2"
            shift
        done
        echo "containers-add image=$(cat "$url") name=${name}" >> "$STUB_DIR/calls.log" ;;
esac
exit 0
EOF

# apptainer: `inspect` finds no revision label.
printf '#!/bin/bash\nexit 0\n' > "$STUBS/apptainer"
chmod +x "$STUBS/babs" "$STUBS/datalad" "$STUBS/apptainer"

# The wrappers source ~/.bashrc and call micromamba and module.
printf 'micromamba() { :; }\nmodule() { :; }\n' > "$FAKE_HOME/.bashrc"
echo "license" > "$FAKE_HOME/license.txt"

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

# Run one wrapper in its own sandbox.
# Usage: run_wrapper <case> <script> <image versions, space-separated; "plain"
#        is the unversioned <app>_bidsapp.sif> [VAR=value ...]
# Sets CASE_DIR, STATUS and OUTPUT. Each image file's content is its own name.
# The site is $SITE, A by default.
run_wrapper() {
    local case_name="$1" script="$2" images="$3" site="${SITE:-A}"
    shift 3
    local app="${script%_babs_script.sh}"
    # The space keeps every path the wrappers get, .env values included, honest.
    CASE_DIR="$TEST_TMPDIR/sand box/$case_name"
    mkdir -p "$CASE_DIR"/{cwd,base,stub,scratch/ants,scratch/fs,scratch/mriqc,scratch/compute} \
        "$CASE_DIR/study/study-TEST/site-${site}/sourcedata/raw"
    local v
    for v in $images; do
        if [ "$v" = plain ]; then
            echo "${app}_bidsapp.sif" > "$CASE_DIR/base/${app}_bidsapp.sif"
        else
            echo "${app}_bidsapp-${v}.sif" > "$CASE_DIR/base/${app}_bidsapp-${v}.sif"
        fi
    done
    # The wrappers read .env from the directory they are started in. %q keeps
    # a temp path with a space in it one value.
    printf '%s=%q\n' \
        BASE_DIR "$CASE_DIR/base" \
        SCRATCH_DIR_ANTS "$CASE_DIR/scratch/ants" \
        SCRATCH_DIR_FS "$CASE_DIR/scratch/fs" \
        SCRATCH_DIR_MRIQC "$CASE_DIR/scratch/mriqc" \
        SCRATCH_DIR_COMPUTE "$CASE_DIR/scratch/compute" \
        DATALAD_SET_DIR "$CASE_DIR/study" \
        FS_LICENSE "$FAKE_HOME/license.txt" > "$CASE_DIR/cwd/.env"
    : > "$CASE_DIR/stub/calls.log"
    # A clean environment: no site modules, no caller's versions or .env. The
    # command substitution also waits for the wrapper's own `tee` to finish.
    STATUS=0
    OUTPUT=$(cd "$CASE_DIR/cwd" && env -i PATH="$STUBS:/usr/bin:/bin" HOME="$FAKE_HOME" \
        RUN_DATE=260101 STUB_DIR="$CASE_DIR/stub" "$@" \
        bash "$REPO_ROOT/$script" "$site" study-TEST 2>&1) || STATUS=$?
}

calls() { cat "$CASE_DIR/stub/calls.log"; }

# One entry per wrapper: "<script> <its version variable>". The check after
# the loop fails for a wrapper in the repo that has no entry here.
wrappers=(
    "ants-nidm_babs_script.sh ANTS_VERSION"
    "freesurfer-nidm_babs_script.sh FS_VERSION"
    "mriqc-nidm_babs_script.sh MRIQC_VERSION"
)
for entry in "${wrappers[@]}"; do
    read -r script version_var <<< "$entry"
    app="${script%_babs_script.sh}"

    # The requested version, with an unversioned image and a neighbouring
    # version beside it: only the requested file may be registered, and the
    # container name and zip suffix must carry the same version.
    run_wrapper "${app}_requested" "$script" "plain 9.8.6 9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -ne 0 ]; then
        fail "$script exited $STATUS with ${version_var}=9.8.7 and its image present:
$OUTPUT"
    fi
    want="containers-add image=${app}_bidsapp-9.8.7.sif name=${app}-bidsapp-9-8-7
babs-init container_name=${app}-bidsapp-9-8-7"
    if [ "$(calls)" != "$want" ]; then
        fail "$script with ${version_var}=9.8.7 registered or initialised the wrong thing.
want:
$want
got:
$(calls)"
    fi
    if ! grep -qx '    ${subid}: "9-8-7"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script with ${version_var}=9.8.7 gave babs init a config that does not zip as 9-8-7:
$(grep -A1 '^zip_foldernames' "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
    fi

    # The requested image is missing: the wrapper must stop instead of using
    # the unversioned or neighbouring image, and must not reach babs.
    run_wrapper "${app}_missing" "$script" "plain 9.8.6" "${version_var}=9.8.7"
    if [ "$STATUS" -eq 0 ]; then
        fail "$script exited 0 although ${app}_bidsapp-9.8.7.sif does not exist"
    fi
    if [ -n "$(calls)" ]; then
        fail "$script used another image when ${app}_bidsapp-9.8.7.sif was missing:
$(calls)"
    fi

    # A second run of the same site on the same RUN_DATE finds the first run's
    # config in the run directory. It must render its own: zip under 9.8.7,
    # not 9.8.6, and read the NIDM derivative it was given, not the first
    # run's.
    run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.6"
    if [ "$STATUS" -ne 0 ] || [ "$(grep -c '^babs-init' "$CASE_DIR/stub/calls.log")" -ne 1 ] \
        || ! grep -q 'derivatives/nidm_4\.5\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script did not complete its first run with ${version_var}=9.8.6 on nidm_4.5.0 (exit $STATUS):
$(calls)"
    fi
    run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7" BABS_NIDM_DERIV=nidm_5.0.0
    if [ "$STATUS" -ne 0 ] \
        || ! grep -qx '    ${subid}: "9-8-7"' "$CASE_DIR/stub/config.yaml" 2>/dev/null \
        || ! grep -q 'derivatives/nidm_5\.0\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null \
        || grep -q 'nidm_4\.5\.0' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script rerun with ${version_var}=9.8.7 BABS_NIDM_DERIV=nidm_5.0.0 (exit $STATUS) did not give babs init a config of its own:
$(grep -E 'subid|origin_url' "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
    fi

    # A read-only config left in the run dir (protecting a hand edit) is
    # replaced, not kept with a false "created" line.
    rerun_config=$(compgen -G "$CASE_DIR/scratch/*/study-TEST_site-A_260101/config_${app}.yaml" || true)
    if [ -z "$rerun_config" ]; then
        fail "$script left no config in its run dir to rerun against"
    else
        sed -i 's|nidm_5\.0\.0|nidm_4.5.0|' "$rerun_config"
        chmod a-w "$rerun_config"
        run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7" BABS_NIDM_DERIV=nidm_5.0.0
        if [ "$STATUS" -ne 0 ] || ! grep -q 'derivatives/nidm_5\.0\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
            fail "$script rerun over a read-only config (exit $STATUS) did not give babs init a fresh config:
$(grep origin_url "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
        fi
        # A config that is a symlink is replaced, and the file it points to
        # is left alone.
        rm -f "$rerun_config"
        echo "keep me" > "$CASE_DIR/link_target.yaml"
        ln -s "$CASE_DIR/link_target.yaml" "$rerun_config"
        run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7"
        if [ "$STATUS" -ne 0 ] || [ "$(cat "$CASE_DIR/link_target.yaml")" != "keep me" ] || [ -L "$rerun_config" ]; then
            fail "$script rerun over a symlinked config (exit $STATUS) wrote through the link or kept it"
        fi
    fi

    # Site and study names go into paths: a "/" or a leading dot is refused
    # before anything is registered.
    for bad in "A/B" ".."; do
        SITE="$bad" run_wrapper "${app}_badname" "$script" "9.8.7" "${version_var}=9.8.7"
        if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
            fail "$script accepted the site name '$bad' (exit $STATUS):
$(calls)"
        fi
    done

    # Two sites of one study on the same RUN_DATE: the second site's babs init
    # must read its own BIDS and NIDM inputs, not the config the first site
    # left behind (issue #23).
    SITE=A run_wrapper "${app}_two_sites" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -ne 0 ] || ! grep -q 'study-TEST/site-A/sourcedata/raw' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script for site A (exit $STATUS) did not give babs init site A's inputs:
$OUTPUT"
    fi
    SITE=B run_wrapper "${app}_two_sites" "$script" "9.8.7" "${version_var}=9.8.7"
    # Each site writes its own log, so two sites started together do not
    # share (and truncate) one file.
    for s in A B; do
        if ! compgen -G "$CASE_DIR/scratch/*/babs_script_study-TEST_site-${s}_260101_*.log" >/dev/null; then
            fail "$script wrote no log named for study-TEST site-${s}:
$(ls "$CASE_DIR"/scratch/*/)"
        fi
    done
    if [ "$STATUS" -ne 0 ] \
        || ! grep -q 'study-TEST/site-B/sourcedata/raw' "$CASE_DIR/stub/config.yaml" 2>/dev/null \
        || grep -q 'site-A/' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script for site B after site A on one RUN_DATE (exit $STATUS) did not give babs init site B's inputs:
$(grep 'origin_url' "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
    fi

    # A version that is not X.Y.Z is refused even when an image of that name
    # exists, before anything is registered.
    run_wrapper "${app}_malformed" "$script" "9.8.7rc1" "${version_var}=9.8.7rc1"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
        fail "$script accepted ${version_var}=9.8.7rc1 (exit $STATUS):
$(calls)"
    fi
done

# Every wrapper in the repo has to be in the list above, or it runs untested.
for wrapper in "$REPO_ROOT"/*_babs_script.sh; do
    listed=0
    for entry in "${wrappers[@]}"; do
        [ "${entry%% *}" = "$(basename "$wrapper")" ] && listed=1
    done
    if [ "$listed" -eq 0 ]; then
        fail "$(basename "$wrapper") is not run by this test; add it to the wrappers list"
    fi
done

# MRIQC_MAX_VOXEL_SIZE needs mriqc-nidm 0.1.3 or later, judged by the version
# the wrapper runs: the option reaches the config for 9.8.7 and stops the
# wrapper before babs for 0.1.2.
run_wrapper mriqc_voxel "mriqc-nidm_babs_script.sh" "9.8.7" MRIQC_VERSION=9.8.7 MRIQC_MAX_VOXEL_SIZE=2
if [ "$STATUS" -ne 0 ] || ! grep -qx '    --max-voxel-size: "2"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
    fail "mriqc wrapper with MRIQC_VERSION=9.8.7 MRIQC_MAX_VOXEL_SIZE=2 (exit $STATUS) did not pass --max-voxel-size: \"2\":
$OUTPUT"
fi
run_wrapper mriqc_voxel_old "mriqc-nidm_babs_script.sh" "0.1.2" MRIQC_VERSION=0.1.2 MRIQC_MAX_VOXEL_SIZE=2
if [ "$STATUS" -eq 0 ] || grep -q '^babs-init' "$CASE_DIR/stub/calls.log"; then
    fail "mriqc wrapper accepted MRIQC_MAX_VOXEL_SIZE for MRIQC_VERSION=0.1.2 (exit $STATUS):
$(calls)"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures wrapper version check(s) failed" >&2
    exit 1
fi
echo "Wrapper version checks passed"
