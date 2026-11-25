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

# run_wrapper reads these per call; a value exported by the caller must not
# reach every case.
unset CASE_SITE CASE_STUDY CASE_ENV_DROP

STUBS="$TEST_TMPDIR/bin"
FAKE_HOME="$TEST_TMPDIR/home"
mkdir -p "$STUBS" "$FAKE_HOME"

# babs: report a version that passes the layout check, and record what `init`
# was given and that `submit` ran. `init` creates the project directory, as
# the wrapper enters it, and refuses one that exists, as babs does.
cat > "$STUBS/babs" <<'EOF'
#!/bin/bash
case "${1:-}" in
    --version) echo "babs v0.5.5.dev32+gea5d6f023" ;;
    init)
        project="${@: -1}"
        if [ -e "$project" ]; then
            echo "refused babs-init: $project exists" >> "$STUB_DIR/calls.log"
            exit 1
        fi
        # A failed init may leave an empty project dir behind.
        if [ -n "${STUB_INIT_FAIL:-}" ]; then
            mkdir -p "$project"
            echo "failed babs-init" >> "$STUB_DIR/calls.log"
            exit 1
        fi
        mkdir -p "$project/.babs"
        name=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --container_name) name="$2" ;;
                --container_config) cp "$2" "$STUB_DIR/config.yaml" ;;
            esac
            shift
        done
        echo "babs-init container_name=${name}" >> "$STUB_DIR/calls.log" ;;
    check-setup) [ -z "${STUB_CHECKSETUP_FAIL:-}" ] || exit 1 ;;
    submit)
        echo "babs-submit" >> "$STUB_DIR/calls.log"
        [ -z "${STUB_SUBMIT_FAIL:-}" ] || exit 1 ;;
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
        echo "containers-add image=$(cat "$url") name=${name}" >> "$STUB_DIR/calls.log"
        # Register a copy, as datalad does, for the wrapper's size check.
        mkdir -p ".datalad/environments/${name}"
        cp "$url" ".datalad/environments/${name}/image" ;;
    run-procedure) [ -z "${STUB_TEXT2GIT_FAIL:-}" ] || exit 1 ;;
    push)
        echo "datalad-push" >> "$STUB_DIR/calls.log"
        # STUB_PUSH_FAIL names the sibling whose push fails.
        [ -z "${STUB_PUSH_FAIL:-}" ] || [ "$3" != "$STUB_PUSH_FAIL" ] || exit 1 ;;
esac
exit 0
EOF

# apptainer: `inspect` finds no labels; `sif list` reports a complete image, its
# last object ending at the file size.
cat > "$STUBS/apptainer" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "sif list" ]; then
    echo "ID   |GROUP   |LINK    |SIF POSITION (start-end)  |TYPE"
    echo "1    |1       |NONE    |0-$(wc -c < "$3")         |FS (Squashfs/*System/amd64)"
fi
exit 0
EOF
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
# The site is $CASE_SITE (A by default) and the study $CASE_STUDY (study-TEST
# by default); $CASE_ENV_DROP names a variable to leave out of the .env.
run_wrapper() {
    local case_name="$1" script="$2" images="$3" site="${CASE_SITE:-A}"
    local study="${CASE_STUDY:-study-TEST}"
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
    if [ -n "${CASE_ENV_DROP:-}" ]; then
        sed -i "/^${CASE_ENV_DROP}=/d" "$CASE_DIR/cwd/.env"
    fi
    : > "$CASE_DIR/stub/calls.log"
    # A clean environment: no site modules, no caller's versions or .env. The
    # command substitution also waits for the wrapper's own `tee` to finish.
    STATUS=0
    OUTPUT=$(cd "$CASE_DIR/cwd" && env -i PATH="$STUBS:/usr/bin:/bin" HOME="$FAKE_HOME" \
        RUN_DATE=260101 STUB_DIR="$CASE_DIR/stub" "$@" \
        bash "$REPO_ROOT/$script" "$site" "$study" 2>&1) || STATUS=$?
}

calls() { cat "$CASE_DIR/stub/calls.log"; }

# Remove the project an earlier run of this case made for a site, as an
# operator does before redoing the site under the default output dir.
rm_project() { rm -rf "$CASE_DIR/study/study-TEST/site-${1:-A}/derivatives/babs-${app}"; }

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
babs-init container_name=${app}-bidsapp-9-8-7
datalad-push
datalad-push
babs-submit"
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
    # project. It must stop before it copies an image or calls babs, and say
    # how to submit into that project: babs init refuses an existing project,
    # and a babs submit there would run the first run's version and inputs.
    run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.6"
    if [ "$STATUS" -ne 0 ] || [ "$(grep -c '^babs-init' "$CASE_DIR/stub/calls.log")" -ne 1 ] \
        || ! grep -q 'derivatives/nidm_5\.0\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script did not complete its first run with ${version_var}=9.8.6 on nidm_5.0.0 (exit $STATUS):
$(calls)"
    fi
    run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7" BABS_NIDM_DERIV=nidm_5.1.0
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] \
        || [[ "$OUTPUT" != *"babs-${app}\" && babs submit"* ]]; then
        fail "$script rerun over site A's existing project (exit $STATUS) did not stop before babs with the command to submit into it:
$(calls)
$OUTPUT"
    fi

    # With the project removed, the rerun finds the first run's config in the
    # run directory. It must render its own: zip under 9.8.7, not 9.8.6, and
    # read the NIDM derivative it was given, not the first run's.
    rm_project
    run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7" BABS_NIDM_DERIV=nidm_5.1.0
    if [ "$STATUS" -ne 0 ] \
        || ! grep -qx '    ${subid}: "9-8-7"' "$CASE_DIR/stub/config.yaml" 2>/dev/null \
        || ! grep -q 'derivatives/nidm_5\.1\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null \
        || grep -q 'nidm_5\.0\.0' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script rerun with ${version_var}=9.8.7 BABS_NIDM_DERIV=nidm_5.1.0 (exit $STATUS) did not give babs init a config of its own:
$(grep -E 'subid|origin_url' "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
    fi

    # A read-only config left in the run dir (protecting a hand edit) is
    # replaced, not kept with a false "created" line.
    rerun_config=$(compgen -G "$CASE_DIR/scratch/*/study-TEST_site-A_260101/config_${app}.yaml" || true)
    if [ -z "$rerun_config" ]; then
        fail "$script left no config in its run dir to rerun against"
    else
        sed -i 's|nidm_5\.1\.0|nidm_5.0.0|' "$rerun_config"
        chmod a-w "$rerun_config"
        rm_project
        run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7" BABS_NIDM_DERIV=nidm_5.1.0
        if [ "$STATUS" -ne 0 ] || ! grep -q 'derivatives/nidm_5\.1\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
            fail "$script rerun over a read-only config (exit $STATUS) did not give babs init a fresh config:
$(grep origin_url "$CASE_DIR/stub/config.yaml" 2>/dev/null || echo '(no config reached babs init)')"
        fi
        # A config that is a symlink is replaced, and the file it points to
        # is left alone.
        rm -f "$rerun_config"
        echo "keep me" > "$CASE_DIR/link_target.yaml"
        ln -s "$CASE_DIR/link_target.yaml" "$rerun_config"
        rm_project
        run_wrapper "${app}_rerun" "$script" "9.8.6 9.8.7" "${version_var}=9.8.7"
        if [ "$STATUS" -ne 0 ] || [ "$(cat "$CASE_DIR/link_target.yaml")" != "keep me" ] || [ -L "$rerun_config" ]; then
            fail "$script rerun over a symlinked config (exit $STATUS) wrote through the link or kept it"
        fi
    fi

    # Site and study names and RUN_DATE go into paths: a "/" or a leading dot
    # is refused before anything is registered.
    for bad in "A/B" ".."; do
        CASE_SITE="$bad" run_wrapper "${app}_badname" "$script" "9.8.7" "${version_var}=9.8.7"
        if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
            fail "$script accepted the site name '$bad' (exit $STATUS):
$(calls)"
        fi
        CASE_STUDY="study-TEST/${bad}" run_wrapper "${app}_badname" "$script" "9.8.7" "${version_var}=9.8.7"
        if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
            fail "$script accepted the study name 'study-TEST/${bad}' (exit $STATUS):
$(calls)"
        fi
        run_wrapper "${app}_badname" "$script" "9.8.7" "${version_var}=9.8.7" RUN_DATE="260101/${bad}"
        if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
            fail "$script accepted RUN_DATE=260101/${bad} (exit $STATUS):
$(calls)"
        fi
    done
    CASE_STUDY=".." run_wrapper "${app}_badname" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
        fail "$script accepted the study name '..' (exit $STATUS):
$(calls)"
    fi

    # Without SCRATCH_DIR_COMPUTE the compute space cannot be made, and the
    # run stops before babs.
    CASE_ENV_DROP=SCRATCH_DIR_COMPUTE run_wrapper "${app}_nocompute" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -eq 0 ] || grep -q '^babs-init' "$CASE_DIR/stub/calls.log"; then
        fail "$script ran without SCRATCH_DIR_COMPUTE in .env (exit $STATUS):
$(calls)"
    fi

    # A relative BABS_OUTPUT_DIR is refused: the wrapper changes directory
    # before babs init, so it would be checked in one place and used in another.
    run_wrapper "${app}_relout" "$script" "9.8.7" "${version_var}=9.8.7" BABS_OUTPUT_DIR=relative/project
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ]; then
        fail "$script accepted a relative BABS_OUTPUT_DIR (exit $STATUS):
$(calls)"
    fi

    # A failed push of the text2git commit stops the run before submit, and a
    # failed babs submit makes the run fail.
    for sibling in input output; do
        run_wrapper "${app}_pushfail_${sibling}" "$script" "9.8.7" "${version_var}=9.8.7" STUB_PUSH_FAIL="$sibling" BABS_SUBMIT_COUNT=2
        if [ "$STATUS" -eq 0 ] || grep -q '^babs-submit' "$CASE_DIR/stub/calls.log" \
            || [[ "$OUTPUT" != *"datalad push --to input --data nothing && datalad push --to output --data nothing"* ]] \
            || [[ "$OUTPUT" != *"&& babs submit --count 2"* ]]; then
            fail "$script went on after the push to the ${sibling} sibling failed (exit $STATUS):
$(calls)"
        fi
    done
    run_wrapper "${app}_t2gfail" "$script" "9.8.7" "${version_var}=9.8.7" STUB_TEXT2GIT_FAIL=1 BABS_SUBMIT_COUNT=2
    if [ "$STATUS" -eq 0 ] || grep -qE '^(datalad-push|babs-submit)' "$CASE_DIR/stub/calls.log" \
        || [[ "$OUTPUT" != *"datalad run-procedure cfg_text2git"* ]] \
        || [[ "$OUTPUT" != *"&& babs submit --count 2"* ]]; then
        fail "$script went on after text2git failed (exit $STATUS):
$(calls)"
    fi
    run_wrapper "${app}_submitfail" "$script" "9.8.7" "${version_var}=9.8.7" STUB_SUBMIT_FAIL=1 BABS_SUBMIT_COUNT=2
    if [ "$STATUS" -eq 0 ] || [[ "$OUTPUT" == *"Script completed"* ]] \
        || [[ "$OUTPUT" != *"&& babs submit --count 2"* ]]; then
        fail "$script reported success after babs submit failed, or its remedy dropped BABS_SUBMIT_COUNT (exit $STATUS):
$OUTPUT"
    fi

    # A failed setup check builds the project, submits nothing, and prints
    # the submit command with the ramp's --count.
    run_wrapper "${app}_checkfail" "$script" "9.8.7" "${version_var}=9.8.7" STUB_CHECKSETUP_FAIL=1 BABS_SUBMIT_COUNT=2
    if [ "$STATUS" -eq 0 ] || grep -q '^babs-submit' "$CASE_DIR/stub/calls.log" \
        || [[ "$OUTPUT" != *"&& babs submit --count 2"* ]]; then
        fail "$script after a failed setup check (exit $STATUS) submitted or dropped --count from its remedy:
$OUTPUT"
    fi

    # What is at the output path decides the message: an empty dir (a babs
    # init that did not finish) is named with rmdir; a dir that is not a
    # project (here the site's derivatives dir) is left alone, with no
    # command that would remove it.
    mkdir -p "$TEST_TMPDIR/sand box/${app}_leftover/study/study-TEST/site-A/derivatives/babs-${app}"
    run_wrapper "${app}_leftover" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"rmdir"* ]]; then
        fail "$script over an empty leftover project dir (exit $STATUS) did not name rmdir:
$OUTPUT"
    fi
    derivs="$CASE_DIR/study/study-TEST/site-A/derivatives"
    mkdir -p "$derivs/other-app"
    run_wrapper "${app}_notproject" "$script" "9.8.7" "${version_var}=9.8.7" BABS_OUTPUT_DIR="$derivs"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"is not a BABS project"* ]] \
        || [[ "$OUTPUT" == *"rmdir"* ]] || [[ "$OUTPUT" == *"rm -"* ]] || [[ "$OUTPUT" == *"babs submit"* ]]; then
        fail "$script with BABS_OUTPUT_DIR at a dir that is not a project (exit $STATUS) gave the wrong advice:
$OUTPUT"
    fi

    # A failed babs init stops the run: nothing is submitted.
    run_wrapper "${app}_initfail" "$script" "9.8.7" "${version_var}=9.8.7" STUB_INIT_FAIL=1
    if [ "$STATUS" -eq 0 ] || grep -q '^babs-submit' "$CASE_DIR/stub/calls.log"; then
        fail "$script went on after babs init failed (exit $STATUS):
$(calls)"
    fi

    # Without its scratch dir in .env the wrapper stops before anything is
    # copied or registered, instead of running in the current directory.
    case "$app" in
        ants-nidm) scratch_var=SCRATCH_DIR_ANTS ;;
        freesurfer-nidm) scratch_var=SCRATCH_DIR_FS ;;
        mriqc-nidm) scratch_var=SCRATCH_DIR_MRIQC ;;
    esac
    CASE_ENV_DROP="$scratch_var" run_wrapper "${app}_noscratch" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [ -n "$(ls -A "$CASE_DIR/cwd" | grep -vx '\.env')" ] \
        || [[ "$OUTPUT" != *"${scratch_var} is not set"* ]]; then
        fail "$script ran without ${scratch_var} in .env, or did not name it (exit $STATUS):
$(calls)
$(ls -A "$CASE_DIR/cwd")"
    fi

    # Two sites of one study on the same RUN_DATE: the second site's babs init
    # must read its own BIDS and NIDM inputs, not the config the first site
    # left behind (issue #23).
    CASE_SITE=A run_wrapper "${app}_two_sites" "$script" "9.8.7" "${version_var}=9.8.7"
    if [ "$STATUS" -ne 0 ] || ! grep -q 'study-TEST/site-A/sourcedata/raw' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script for site A (exit $STATUS) did not give babs init site A's inputs:
$OUTPUT"
    fi
    CASE_SITE=B run_wrapper "${app}_two_sites" "$script" "9.8.7" "${version_var}=9.8.7"
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
    # Each site has its own run dir, so site A's config still records site A's
    # run after site B's.
    a_config=$(compgen -G "$CASE_DIR/scratch/*/study-TEST_site-A_260101/config_${app}.yaml" || true)
    b_config=$(compgen -G "$CASE_DIR/scratch/*/study-TEST_site-B_260101/config_${app}.yaml" || true)
    if [ -z "$a_config" ] || [ -z "$b_config" ] \
        || ! grep -q 'study-TEST/site-A/sourcedata/raw' "$a_config"; then
        fail "$script did not keep one run dir per site: after sites A and B on one RUN_DATE the scratch dir holds:
$(ls "$CASE_DIR"/scratch/*/)"
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

# MRIQC_MAX_VOXEL_SIZE reaches the config for 9.8.7. For 0.1.2 the wrapper
# stops earlier, at the mriqc-nidm 0.1.3 floor that --modalities needs (and,
# under the nidm_5.0.0 default, at babs_require_nidm_match); the voxel-size
# version check in babs_configure_max_voxel_size is unreachable from the
# wrapper and is tested by the direct calls in test_babs_pr369.sh.
run_wrapper mriqc_voxel "mriqc-nidm_babs_script.sh" "9.8.7" MRIQC_VERSION=9.8.7 MRIQC_MAX_VOXEL_SIZE=2
if [ "$STATUS" -ne 0 ] || ! grep -qx '    --max-voxel-size: "2"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
    fail "mriqc wrapper with MRIQC_VERSION=9.8.7 MRIQC_MAX_VOXEL_SIZE=2 (exit $STATUS) did not pass --max-voxel-size: \"2\":
$OUTPUT"
fi
run_wrapper mriqc_voxel_old "mriqc-nidm_babs_script.sh" "0.1.2" MRIQC_VERSION=0.1.2 MRIQC_MAX_VOXEL_SIZE=2
if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"--modalities in config_mriqc-nidm.yaml needs MRIQC_VERSION 0.1.3 or later, got 0.1.2"* ]]; then
    fail "mriqc wrapper with MRIQC_VERSION=0.1.2 MRIQC_MAX_VOXEL_SIZE=2 (exit $STATUS) did not stop at the version floor before babs:
$OUTPUT"
fi

# The input NIDM and the image's PyNIDM must agree: "<script> <version
# variable> <a version on PyNIDM 4.5.0> <the first version on PyNIDM 5>".
nidm_pairs=(
    "ants-nidm_babs_script.sh ANTS_VERSION 0.2.2 0.2.3"
    "freesurfer-nidm_babs_script.sh FS_VERSION 0.1.3 0.1.4"
    "mriqc-nidm_babs_script.sh MRIQC_VERSION 0.1.3 0.1.4"
)
for entry in "${nidm_pairs[@]}"; do
    read -r script version_var old new <<< "$entry"
    app="${script%_babs_script.sh}"
    run_wrapper "${app}_nidm_old_default" "$script" "$old" "${version_var}=$old"
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"runs PyNIDM 4, but BABS_NIDM_DERIV=nidm_5.0.0"* ]]; then
        fail "$script with ${version_var}=$old and the nidm_5.0.0 default (exit $STATUS) did not stop before babs:
$OUTPUT"
    fi
    run_wrapper "${app}_nidm_old_4" "$script" "$old" "${version_var}=$old" BABS_NIDM_DERIV=nidm_4.5.0
    if [ "$STATUS" -ne 0 ] || ! grep -q '^babs-init' "$CASE_DIR/stub/calls.log" \
        || ! grep -q 'derivatives/nidm_4\.5\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script with ${version_var}=$old BABS_NIDM_DERIV=nidm_4.5.0 exited $STATUS:
$OUTPUT"
    fi
    run_wrapper "${app}_nidm_new_4" "$script" "$new" "${version_var}=$new" BABS_NIDM_DERIV=nidm_4.5.0
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"runs PyNIDM 5, but BABS_NIDM_DERIV=nidm_4.5.0"* ]]; then
        fail "$script with ${version_var}=$new BABS_NIDM_DERIV=nidm_4.5.0 (exit $STATUS) did not stop before babs:
$OUTPUT"
    fi
    run_wrapper "${app}_nidm_other" "$script" "$old" "${version_var}=$old" BABS_NIDM_DERIV=nidm
    if [ "$STATUS" -ne 0 ] || ! grep -q '^babs-init' "$CASE_DIR/stub/calls.log" \
        || ! grep -q 'derivatives/nidm"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script with BABS_NIDM_DERIV=nidm (not versioned) did not run on that folder (exit $STATUS):
$OUTPUT"
    fi
    # A zero-padded major is the same release.
    run_wrapper "${app}_nidm_padded" "$script" "$new" "${version_var}=$new" BABS_NIDM_DERIV=nidm_05.0.0
    if [ "$STATUS" -ne 0 ] || ! grep -q '^babs-init' "$CASE_DIR/stub/calls.log" \
        || ! grep -q 'derivatives/nidm_05\.0\.0"' "$CASE_DIR/stub/config.yaml" 2>/dev/null; then
        fail "$script with ${version_var}=$new BABS_NIDM_DERIV=nidm_05.0.0 exited $STATUS:
$OUTPUT"
    fi
    # A release with no known image boundary is refused with that reason.
    run_wrapper "${app}_nidm_unknown" "$script" "$new" "${version_var}=$new" BABS_NIDM_DERIV=nidm_6.0.0
    if [ "$STATUS" -eq 0 ] || [ -n "$(calls)" ] || [[ "$OUTPUT" != *"no image boundary is known"* ]]; then
        fail "$script with BABS_NIDM_DERIV=nidm_6.0.0 (exit $STATUS) did not stop for an unknown PyNIDM release:
$OUTPUT"
    fi
done

# With no version variable set, each wrapper runs the default the README's
# table names, so the table and the scripts cannot drift apart.
for entry in "${wrappers[@]}"; do
    read -r script version_var <<< "$entry"
    app="${script%_babs_script.sh}"
    default=$(sed -n "s/^| \`$script\` | \`$version_var\` | \`\([0-9.]*\)\` |$/\1/p" "$REPO_ROOT/README.md")
    if [ -z "$default" ]; then
        fail "README.md has no defaults-table row for $script"
        continue
    fi
    run_wrapper "${app}_default" "$script" "$default"
    if [ "$STATUS" -ne 0 ] || ! grep -qx "containers-add image=${app}_bidsapp-${default}.sif name=${app}-bidsapp-${default//./-}" "$CASE_DIR/stub/calls.log"; then
        fail "$script with no ${version_var} did not run the README's default $default (exit $STATUS):
$(calls)"
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures wrapper version check(s) failed" >&2
    exit 1
fi
echo "Wrapper version checks passed"
