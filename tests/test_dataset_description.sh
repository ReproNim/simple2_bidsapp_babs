#!/usr/bin/env bash
# babs_dataset_description.sh writes a BIDS dataset_description.json and a
# .bidsignore at the root of a harvested BABS project, from what the project
# records. This builds fake projects with git and runs the real script with
# stand-ins for babs, datalad, git-annex and apptainer on PATH, in a temporary
# directory: no real image or dataset is read. When datalad and git-annex are
# installed, one case also runs the real `datalad run` and `datalad save`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/babs_dataset_description.sh"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

REAL_DATALAD_DIR=""
if command -v datalad >/dev/null 2>&1 && command -v git-annex >/dev/null 2>&1; then
    REAL_DATALAD_DIR="$(dirname "$(command -v datalad)"):$(dirname "$(command -v git-annex)")"
fi

STUBS="$TEST_TMPDIR/bin"
FAKE_HOME="$TEST_TMPDIR/home"
mkdir -p "$STUBS" "$FAKE_HOME"
git config --file "$FAKE_HOME/.gitconfig" user.name "Test"
git config --file "$FAKE_HOME/.gitconfig" user.email "test@example.org"
git config --file "$FAKE_HOME/.gitconfig" init.defaultBranch main

cat > "$STUBS/babs" <<'EOF'
#!/bin/bash
[ "${1:-}" = "--version" ] && echo "babs v0.5.5.dev32+gabcdef123"
exit 0
EOF

cat > "$STUBS/git-annex" <<'EOF'
#!/bin/bash
exit 0
EOF

# apptainer: the "image" is a text file holding its own labels.
cat > "$STUBS/apptainer" <<'EOF'
#!/bin/bash
[ "${1:-} ${2:-}" = "inspect --labels" ] && cat "$3"
exit 0
EOF

# datalad: `run` executes the command it is given (undoing the {{ }} escapes of
# the command text, as datalad does) and commits; `save` is recorded with the
# directory it ran in.
cat > "$STUBS/datalad" <<'EOF'
#!/bin/bash
case "${1:-}" in
    run)
        shift
        msg=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -d|--output|--input) shift 2 ;;
                -m) msg="$2"; shift 2 ;;
                *) break ;;
            esac
        done
        args=()
        for a in "$@"; do
            a="${a//\{\{/\{}"
            args+=("${a//\}\}/\}}")
        done
        echo "datalad-run" >> "$STUB_DIR/calls.log"
        "${args[@]}"
        git add -A .
        git commit -q -m "$msg" ;;
    save)
        shift; echo "datalad-save cwd=$PWD args=$*" >> "$STUB_DIR/calls.log" ;;
esac
exit 0
EOF
chmod +x "$STUBS"/*

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

# Build a harvested project: <site>/derivatives/<dir>, a git repository with
# the app's container registered, two input subdatasets and one subject.
# Usage: make_project <case> <app> <X.Y.Z> [<dir name>]
# Sets CASE_DIR, SITE_DIR and PROJECT_DIR.
make_project() {
    local case_name="$1" app="$2" version="$3"
    local dashed="${version//./-}" repo="${app}_bidsapp"
    local dir="${4:-babs-${app}-${dashed}}"
    CASE_DIR="$TEST_TMPDIR/$case_name"
    SITE_DIR="$CASE_DIR/study-TEST/site-A"
    PROJECT_DIR="$SITE_DIR/derivatives/$dir"
    mkdir -p "$PROJECT_DIR" "$CASE_DIR/stub"
    : > "$CASE_DIR/stub/calls.log"
    (
        export HOME="$FAKE_HOME"
        git -C "$SITE_DIR" init -q
        cd "$PROJECT_DIR"
        git init -q
        mkdir -p sourcedata/BIDS sourcedata/NIDM "containers/.datalad/environments/${app}-bidsapp-${dashed}" sub-01/ses-1
        git update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,sourcedata/BIDS"
        git update-index --add --cacheinfo "160000,2222222222222222222222222222222222222222,sourcedata/NIDM"
        git config -f .gitmodules submodule.sourcedata/BIDS.path sourcedata/BIDS
        git config -f .gitmodules submodule.sourcedata/BIDS.url /data/raw
        git config -f .gitmodules submodule.sourcedata/NIDM.path sourcedata/NIDM
        git config -f .gitmodules submodule.sourcedata/NIDM.url /data/nidm_5.0.0
        git config -f containers/.datalad/config "datalad.containers.${app}-bidsapp-${dashed}.image" \
            ".datalad/environments/${app}-bidsapp-${dashed}/image"
        cat > "containers/.datalad/environments/${app}-bidsapp-${dashed}/image" <<LABELS
org.opencontainers.image.revision: 0123456789abcdef0123456789abcdef01234567
org.opencontainers.image.source: https://github.com/ReproNim/${repo}
org.opencontainers.image.version: ${version}
LABELS
        echo ttl > sub-01/ses-1/nidm.ttl
        : > "sub-01_ses-1_sub-01-${dashed}.zip"
        git add .gitmodules containers sub-01 "sub-01_ses-1_sub-01-${dashed}.zip"
        git commit -q -m "harvested"
    )
}

# Run the script in a clean environment; sets STATUS and OUTPUT.
# Usage: run_script <args...>
run_script() {
    STATUS=0
    OUTPUT=$(env -i PATH="$STUBS:/usr/bin:/bin" HOME="$FAKE_HOME" STUB_DIR="$CASE_DIR/stub" \
        bash "$SCRIPT" "$@" 2>&1) || STATUS=$?
}

head_of() { git -C "$PROJECT_DIR" rev-parse HEAD; }
calls() { cat "$CASE_DIR/stub/calls.log"; }
count_calls() { grep -c "^$1" "$CASE_DIR/stub/calls.log" || true; }

# --- the content, for each of the three apps -----------------------------
for entry in "ants-nidm 0.2.3 https://github.com/ReproNim/ants-nidm_bidsapp" \
             "freesurfer-nidm 0.1.4 https://github.com/ReproNim/freesurfer-nidm_bidsapp" \
             "mriqc-nidm 0.1.5 https://github.com/ReproNim/mriqc-nidm_bidsapp"; do
    read -r app version code_url <<< "$entry"
    make_project "content_$app" "$app" "$version"
    run_script "$PROJECT_DIR"
    [ "$STATUS" -eq 0 ] || fail "$app: exit $STATUS on a harvested project:
$OUTPUT"
    dd="$PROJECT_DIR/dataset_description.json"
    if ! jq -e . "$dd" >/dev/null 2>&1; then
        fail "$app: dataset_description.json is not valid JSON"
        continue
    fi
    got=$(jq -c '[.Name, .BIDSVersion, .DatasetType, .GeneratedBy[0].Name, .GeneratedBy[0].Version,
                  .GeneratedBy[0].CodeURL, .GeneratedBy[0].Container.Type, .GeneratedBy[0].Container.Tag,
                  .GeneratedBy[1].Name, .GeneratedBy[1].Version]' "$dd")
    want=$(jq -c -n --arg app "$app" --arg v "$version" --arg url "$code_url" '[
        "TEST A: \($app) \($v) derivatives", "1.11.2", "derivative", $app, $v, $url, "apptainer",
        "\($url | split("/")[-1])-\($v).sif", "BABS", "0.5.5.dev32+gabcdef123"]')
    [ "$got" = "$want" ] || fail "$app: wrong GeneratedBy/Name content.
want: $want
got:  $got"
    desc=$(jq -r '.GeneratedBy[0].Description' "$dd")
    case "$desc" in
        *0123456789abcdef0123456789abcdef01234567*) ;;
        *) fail "$app: the image revision is not in the GeneratedBy description: $desc" ;;
    esac
    got=$(jq -c '.SourceDatasets' "$dd")
    want='[{"URL":"/data/raw","Version":"1111111111111111111111111111111111111111"},{"URL":"/data/nidm_5.0.0","Version":"2222222222222222222222222222222222222222"}]'
    [ "$got" = "$want" ] || fail "$app: wrong SourceDatasets.
want: $want
got:  $got"
    grep -qx '/sub-\*' "$PROJECT_DIR/.bidsignore" 2>/dev/null || fail "$app: .bidsignore does not hold /sub-*"
    [ "$(git -C "$PROJECT_DIR" log -1 --format=%s)" = "Write the BIDS dataset_description.json and .bidsignore" ] \
        || fail "$app: the files were not committed by the datalad run"
    [ "$(count_calls datalad-run)" -eq 1 ] || fail "$app: expected one datalad run, got: $(calls)"
    want_save="datalad-save cwd=$SITE_DIR args=-d $SITE_DIR -m Update derivatives/babs-${app}-${version//./-} pointer after dataset_description -- derivatives/babs-${app}-${version//./-}"
    [ "$(grep '^datalad-save' "$CASE_DIR/stub/calls.log")" = "$want_save" ] || fail "$app: wrong site pointer update.
want: $want_save
got:  $(grep '^datalad-save' "$CASE_DIR/stub/calls.log")"
done

# --- the folder name must hold the app name -------------------------------
make_project name_rule ants-nidm 0.2.3 pilot_ants
before=$(head_of)
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] || fail "a folder name without the app name was accepted"
case "$OUTPUT" in *"does not contain the app name 'ants-nidm'"*) ;; *) fail "no folder-name message: $OUTPUT" ;; esac
[ ! -e "$PROJECT_DIR/dataset_description.json" ] && [ "$(head_of)" = "$before" ] || fail "files were written despite the folder-name refusal"

# --- an unharvested project (zips, no sub-*/ directory) -------------------
make_project unharvested ants-nidm 0.2.3
git -C "$PROJECT_DIR" rm -rq sub-01 && git -C "$PROJECT_DIR" -c user.name=T -c user.email=t@e commit -q -m "no subjects"
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] || fail "an unharvested project was accepted"
case "$OUTPUT" in *"post_babs.sh"*) ;; *) fail "the refusal does not point at post_babs.sh: $OUTPUT" ;; esac
[ ! -e "$PROJECT_DIR/dataset_description.json" ] || fail "files were written for an unharvested project"

# --- a rerun with the same content changes nothing ------------------------
make_project rerun ants-nidm 0.2.3
run_script "$PROJECT_DIR"
first=$(head_of)
run_script "$PROJECT_DIR"
[ "$STATUS" -eq 0 ] || fail "rerun exited $STATUS:
$OUTPUT"
[ "$(head_of)" = "$first" ] || fail "rerun made a new commit"
[ "$(count_calls datalad-run)" -eq 1 ] || fail "rerun ran datalad run again: $(calls)"
case "$OUTPUT" in *"up to date"*) ;; *) fail "rerun did not say it is up to date: $OUTPUT" ;; esac

# --- differing content stops, and --force replaces it ---------------------
make_project differs ants-nidm 0.2.3
run_script "$PROJECT_DIR"
printf '{"Name": "hand written"}\n' > "$PROJECT_DIR/dataset_description.json"
git -C "$PROJECT_DIR" add dataset_description.json
git -C "$PROJECT_DIR" -c user.name=T -c user.email=t@e commit -q -m "edited by hand"
edited=$(head_of)
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] || fail "differing dataset_description.json was overwritten without --force"
case "$OUTPUT" in *'+  "BIDSVersion": "1.11.2"'*'-{"Name": "hand written"}'* | *'-{"Name": "hand written"}'*'+  "BIDSVersion": "1.11.2"'*) ;; *) fail "no diff shown: $OUTPUT" ;; esac
[ "$(head_of)" = "$edited" ] && [ "$(cat "$PROJECT_DIR/dataset_description.json")" = '{"Name": "hand written"}' ] \
    || fail "the file changed without --force"
[ "$(count_calls datalad-run)" -eq 1 ] || fail "datalad run ran despite the conflict: $(calls)"
run_script --force "$PROJECT_DIR"
[ "$STATUS" -eq 0 ] || fail "--force exited $STATUS:
$OUTPUT"
[ "$(jq -r .DatasetType "$PROJECT_DIR/dataset_description.json" 2>/dev/null)" = derivative ] || fail "--force did not replace the file"
[ "$(count_calls datalad-run)" -eq 2 ] || fail "--force did not run datalad run: $(calls)"
run_script "$PROJECT_DIR"
[ "$STATUS" -eq 0 ] && case "$OUTPUT" in *"up to date"*) true ;; *) false ;; esac || fail "a rerun after --force is not up to date: $OUTPUT"

# --- other refusals ---------------------------------------------------------
make_project dirty ants-nidm 0.2.3
echo changed >> "$PROJECT_DIR/sub-01/ses-1/nidm.ttl"
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] && [ ! -e "$PROJECT_DIR/dataset_description.json" ] || fail "a project with uncommitted changes was accepted"

make_project badlabel ants-nidm 0.2.3
sed -i 's/^org.opencontainers.image.version: .*/org.opencontainers.image.version: 0.2.2/' \
    "$PROJECT_DIR/containers/.datalad/environments/ants-nidm-bidsapp-0-2-3/image"
git -C "$PROJECT_DIR" -c user.name=T -c user.email=t@e commit -q -am "relabel"
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] && [ ! -e "$PROJECT_DIR/dataset_description.json" ] || fail "an image labelled with another version was accepted"

make_project nocontainer ants-nidm 0.2.3
git -C "$PROJECT_DIR" rm -rq containers && git -C "$PROJECT_DIR" -c user.name=T -c user.email=t@e commit -q -m "no container"
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] && [ ! -e "$PROJECT_DIR/dataset_description.json" ] || fail "a project without a container was accepted"

make_project twocontainers ants-nidm 0.2.3
git config -f "$PROJECT_DIR/containers/.datalad/config" datalad.containers.ants-nidm-bidsapp-0-2-2.image .datalad/environments/ants-nidm-bidsapp-0-2-2/image
git -C "$PROJECT_DIR" -c user.name=T -c user.email=t@e commit -q -am "second container"
run_script "$PROJECT_DIR"
[ "$STATUS" -ne 0 ] && [ ! -e "$PROJECT_DIR/dataset_description.json" ] || fail "a project with two registered containers was accepted"

# --- real datalad: the JSON braces in the command text survive a run --------
if [ -n "$REAL_DATALAD_DIR" ]; then
    make_project real_datalad ants-nidm 0.2.3
    rm -rf "$SITE_DIR/.git" "$PROJECT_DIR/.git"
    if ! (
        export HOME="$FAKE_HOME"
        cd "$PROJECT_DIR"
        # Text in git, as in a BABS project; the inputs are gitlinks as above.
        datalad create -f -c text2git . >/dev/null
        git update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,sourcedata/BIDS"
        git update-index --add --cacheinfo "160000,2222222222222222222222222222222222222222,sourcedata/NIDM"
        git add .
        git commit -q -m harvested
        cd "$SITE_DIR"
        datalad create -f . >/dev/null
        datalad save -d . -m "register" derivatives/babs-ants-nidm-0-2-3 >/dev/null
    ) > "$CASE_DIR/build.log" 2>&1; then
        fail "could not build the real-datalad project: $(cat "$CASE_DIR/build.log")"
    else
        # Only babs and apptainer are stand-ins; datalad and git-annex are real.
        REAL_STUBS="$TEST_TMPDIR/real_bin"
        mkdir -p "$REAL_STUBS"
        cp "$STUBS/babs" "$STUBS/apptainer" "$REAL_STUBS/"
        STATUS=0
        OUTPUT=$(env -i PATH="$REAL_STUBS:$REAL_DATALAD_DIR:/usr/bin:/bin" HOME="$FAKE_HOME" \
            bash "$SCRIPT" "$PROJECT_DIR" 2>&1) || STATUS=$?
        [ "$STATUS" -eq 0 ] || fail "real datalad: exit $STATUS:
$OUTPUT"
        jq -e '.DatasetType == "derivative" and .GeneratedBy[0].Container.Type == "apptainer"
               and (.SourceDatasets | length == 2)' "$PROJECT_DIR/dataset_description.json" >/dev/null 2>&1 \
            || fail "real datalad: dataset_description.json is wrong or missing"
        git -C "$PROJECT_DIR" log -1 --format=%B | grep -q 'DATALAD RUNCMD' || fail "real datalad: the run is not recorded in the commit"
        [ "$(git -C "$SITE_DIR" ls-tree HEAD derivatives/babs-ants-nidm-0-2-3 | awk '{print $3}')" = "$(head_of)" ] \
            || fail "real datalad: the site dataset does not point at the project's new commit"
        STATUS=0
        OUTPUT=$(env -i PATH="$REAL_STUBS:$REAL_DATALAD_DIR:/usr/bin:/bin" HOME="$FAKE_HOME" \
            bash "$SCRIPT" "$PROJECT_DIR" 2>&1) || STATUS=$?
        { [ "$STATUS" -eq 0 ] && case "$OUTPUT" in *"up to date"*) true ;; *) false ;; esac; } \
            || fail "real datalad: rerun is not a no-op: $OUTPUT"
    fi
else
    echo "SKIP: datalad and git-annex not on PATH; the real-datalad case did not run"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "OK"
