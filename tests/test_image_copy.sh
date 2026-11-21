#!/usr/bin/env bash
# babs_setup_container must stop, with an error and no partial .sif left in
# the run directory, when copying the app image fails or comes out short.
# cp is replaced by a stand-in on PATH; no real image is read.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

STUBS="$TEST_TMPDIR/bin"
mkdir -p "$STUBS"
REAL_CP="$(command -v cp)"

# Modes: ok (real copy), fail (partial file, exit 1), short (partial file,
# exit 0), kill (partial file, then SIGKILL of the calling shell, so no cleanup can run).
# A directory target is resolved as cp does, so a case cannot pass because
# the stand-in wrote nothing.
cat > "$STUBS/cp" <<STUB
#!/bin/bash
dest="\$2"
[ -d "\$dest" ] && dest="\$dest/\$(basename "\$1")"
# CP_NO_FINAL=1: fail when the final name is still occupied while the copy is
# written, as an earlier copy kept there doubles the space a copy needs.
if [ -n "\${CP_NO_FINAL:-}" ] && [ -e "\${dest%.partial}" ]; then
    echo "final name still occupied during the copy" >&2; exit 1
fi
case "\${CP_MODE:-ok}" in
    ok) exec "$REAL_CP" "\$@" ;;
    fail) head -c 10 "\$1" > "\$dest"; exit 1 ;;
    short) head -c 10 "\$1" > "\$dest"; exit 0 ;;
    kill) head -c 10 "\$1" > "\$dest"; kill -9 \$PPID ;;
esac
STUB
chmod +x "$STUBS/cp"

# datalad stand-in: reaching containers-add means the image was accepted.
# containers-add registers a copy of the image, as datalad does; DL_MODE=fail
# makes it fail, DL_MODE=short makes the registered copy short.
cat > "$STUBS/datalad" <<STUB
#!/bin/bash
echo "datalad \$*" >> "\$STUB_DIR/calls.log"
case "\$1" in
    create) mkdir -p "\${@: -1}/.datalad"; : > "\${@: -1}/.datalad/config" ;;
    containers-add)
        [ "\${DL_MODE:-ok}" != fail ] || exit 1
        name="\${@: -1}"
        url="\$3"
        mkdir -p ".datalad/environments/\$name"
        echo "[datalad \"containers.\$name\"]" >> .datalad/config
        if [ "\${DL_MODE:-ok}" = short ]; then
            head -c 10 "\$url" > ".datalad/environments/\$name/image"
        else
            "$REAL_CP" "\$url" ".datalad/environments/\$name/image"
        fi ;;
esac
exit 0
STUB
chmod +x "$STUBS/datalad"

# apptainer stand-in. APPT_MODE=fail makes inspect and sif list fail, as on a
# file that is not an image. inspect reports APPT_VERSION as the version
# label, and an app source label when APPT_SOURCE is set. sif list reports a
# last object ending at the file size, or at APPT_SIF_END when set.
cat > "$STUBS/apptainer" <<'STUB'
#!/bin/bash
[ "${APPT_MODE:-ok}" != fail ] || { echo "FATAL: not a SIF file" >&2; exit 255; }
case "$1 $2" in
    "inspect --labels")
        [ -z "${APPT_SOURCE:-}" ] || echo "org.opencontainers.image.source: $APPT_SOURCE"
        [ -z "${APPT_VERSION:-}" ] || echo "org.opencontainers.image.version: $APPT_VERSION" ;;
    "sif list")
        if [ -n "${APPT_SIF_GARBLED:-}" ]; then echo "1 1 NONE 0-64 FS"; exit 0; fi
        end="${APPT_SIF_END:-$(wc -c < "$3")}"
        echo "ID   |GROUP   |LINK    |SIF POSITION (start-end)  |TYPE"
        echo "1    |1       |NONE    |32-64                     |Def.FILE"
        echo "2    |1       |NONE    |64-$end                   |FS (Squashfs/*System/amd64)" ;;
esac
exit 0
STUB
chmod +x "$STUBS/apptainer"

export STUB_DIR="$TEST_TMPDIR"
export BASE_DIR="$TEST_TMPDIR/images"
mkdir -p "$BASE_DIR"
head -c 4096 /dev/zero > "$BASE_DIR/app.sif"
head -c 4096 /dev/zero > "$BASE_DIR/app_bidsapp-1.2.3.sif"

# run_case <mode> <dir> [sif_filename] [VAR=value ...]: run the function in a
# subshell, as it can `exit`.
run_case() {
    local mode="$1" dir="$TEST_TMPDIR/$2" sif="${3:-app.sif}"
    shift 2; [ $# -eq 0 ] || shift
    mkdir -p "$dir"
    : > "$TEST_TMPDIR/calls.log"
    set +e
    (
        cd "$dir"
        PATH="$STUBS:$PATH" CP_MODE="$mode"
        export PATH CP_MODE
        [ $# -eq 0 ] || export "$@"
        source "$REPO_ROOT/babs_common.sh"
        babs_log_image_revision() { :; }
        babs_setup_container ants ants-ds ants-container "$sif"
    ) > "$dir.out" 2>&1
    ec=$?
    set -e
}

# expect_stop <case> <what> <error pattern>: the case exited non-zero with
# that error.
expect_stop() {
    [ "$ec" -ne 0 ] || { echo "FAIL: $2 exited 0"; cat "$TEST_TMPDIR/$1.out"; exit 1; }
    grep -q "$3" "$TEST_TMPDIR/$1.out" \
        || { echo "FAIL: $2 printed no matching error"; cat "$TEST_TMPDIR/$1.out"; exit 1; }
}

for mode in fail short; do
    run_case "$mode" "run_$mode"
    [ "$ec" -ne 0 ] || { echo "FAIL: $mode copy exited 0"; cat "$TEST_TMPDIR/run_$mode.out"; exit 1; }
    grep -q '^ERROR: .*removed the partial file' "$TEST_TMPDIR/run_$mode.out" \
        || { echo "FAIL: $mode copy printed no error"; cat "$TEST_TMPDIR/run_$mode.out"; exit 1; }
    [ ! -e "$TEST_TMPDIR/run_$mode/app.sif" ] \
        || { echo "FAIL: $mode copy left a partial app.sif"; exit 1; }
    ! grep -q containers-add "$TEST_TMPDIR/calls.log" \
        || { echo "FAIL: $mode copy reached datalad containers-add"; exit 1; }
done

# A killed copy leaves no file at the final name, so a rerun cannot mistake
# it for a finished image.
run_case kill run_kill
[ "$ec" -ne 0 ] || { echo "FAIL: killed copy exited 0"; exit 1; }
[ ! -e "$TEST_TMPDIR/run_kill/app.sif" ] \
    || { echo "FAIL: killed copy left a file at app.sif"; exit 1; }

# A stale .partial from an earlier run does not block a fresh copy. It is a
# symlink to a file outside the run directory here: copying through it would
# overwrite that file, so it must be removed first.
mkdir -p "$TEST_TMPDIR/run_stale"
echo victim > "$TEST_TMPDIR/victim"
ln -s "$TEST_TMPDIR/victim" "$TEST_TMPDIR/run_stale/app.sif.partial"
run_case ok run_stale
[ "$ec" -eq 0 ] || { echo "FAIL: stale .partial blocked the copy"; exit 1; }
[ "$(cat "$TEST_TMPDIR/victim")" = victim ] \
    || { echo "FAIL: the copy wrote through a stale .partial symlink"; exit 1; }
grep -q containers-add "$TEST_TMPDIR/calls.log" \
    || { echo "FAIL: copy after a stale .partial did not reach containers-add"; exit 1; }
[ ! -e "$TEST_TMPDIR/run_stale/app.sif.partial" ] \
    || { echo "FAIL: stale .partial was left behind"; exit 1; }

# A complete copy goes through to containers-add.
run_case ok run_ok
[ "$ec" -eq 0 ] || { echo "FAIL: complete copy exited $ec"; cat "$TEST_TMPDIR/run_ok.out"; exit 1; }
grep -q containers-add "$TEST_TMPDIR/calls.log" \
    || { echo "FAIL: complete copy did not reach containers-add"; exit 1; }

# A source apptainer cannot read is not copied.
run_case ok run_badsrc app.sif APPT_MODE=fail
expect_stop run_badsrc "unreadable source" '^ERROR: apptainer cannot read'
[ ! -e "$TEST_TMPDIR/run_badsrc/app.sif" ] || { echo "FAIL: unreadable source was copied"; exit 1; }
! grep -q containers-add "$TEST_TMPDIR/calls.log" || { echo "FAIL: unreadable source reached containers-add"; exit 1; }

# A version label that disagrees with the filename stops setup; a matching
# label goes through.
run_case ok run_wrongver app_bidsapp-1.2.3.sif APPT_VERSION=1.2.4 APPT_SOURCE=https://example.org/app
expect_stop run_wrongver "wrong version label" 'labelled version 1.2.4, but its name asks for 1.2.3'
! grep -q containers-add "$TEST_TMPDIR/calls.log" || { echo "FAIL: wrong version label reached containers-add"; exit 1; }
run_case ok run_rightver app_bidsapp-1.2.3.sif APPT_VERSION=1.2.3 APPT_SOURCE=https://example.org/app
[ "$ec" -eq 0 ] || { echo "FAIL: matching version label exited $ec"; cat "$TEST_TMPDIR/run_rightver.out"; exit 1; }
# An image built before the app set its own version label carries its base
# image's (22.04 on the Ubuntu and CUDA bases), with or without the app's
# source label; that is not compared.
run_case ok run_basever app_bidsapp-1.2.3.sif APPT_VERSION=22.04 APPT_SOURCE=https://example.org/app
[ "$ec" -eq 0 ] || { echo "FAIL: an inherited base-image version label was refused"; cat "$TEST_TMPDIR/run_basever.out"; exit 1; }

# A source shorter than its SIF objects say (a build or copy cut short) is
# not copied.
run_case ok run_truncated app.sif APPT_SIF_END=99999
expect_stop run_truncated "truncated source" 'is 4096 bytes, but its SIF objects end at byte 99999; the image is incomplete'
# A file longer than its SIF objects, and a sif list that cannot be read, are
# refused with their own messages.
run_case ok run_long app.sif APPT_SIF_END=100
expect_stop run_long "file longer than its SIF objects" 'longer than its SIF objects (they end at byte 100)'
run_case ok run_garbled app.sif APPT_SIF_GARBLED=1
expect_stop run_garbled "unreadable sif list" '^ERROR: could not read the SIF object list'
! grep -q containers-add "$TEST_TMPDIR/calls.log" || { echo "FAIL: truncated source reached containers-add"; exit 1; }

# A failed or short registration by containers-add stops setup.
run_case ok run_dlfail app.sif DL_MODE=fail
expect_stop run_dlfail "failed containers-add" '^ERROR: datalad containers-add failed'
[ ! -e "$TEST_TMPDIR/run_dlfail/app.sif" ] || { echo "FAIL: failed containers-add left the run directory copy"; exit 1; }
run_case ok run_dlshort app.sif DL_MODE=short
expect_stop run_dlshort "short registered image" '^ERROR: the registered image .* is 10 bytes, expected 4096'
grep -q "chmod -R u+w '.*/run_dlshort/ants-ds' && rm -rf '.*/run_dlshort/ants-ds'" "$TEST_TMPDIR/run_dlshort.out" \
    || { echo "FAIL: short registered image error does not give the removal command"; exit 1; }
[ ! -e "$TEST_TMPDIR/run_dlshort/app.sif" ] || { echo "FAIL: short registration left the run directory copy"; exit 1; }
# A rerun in the same run directory finds the container registered and must
# check that copy again rather than skip setup.
run_case ok run_dlshort
expect_stop run_dlshort "rerun over a short registered image" '^ERROR: the registered image .* is 10 bytes, expected 4096'
# A rerun over a complete registration skips setup.
run_case ok run_ok
[ "$ec" -eq 0 ] && grep -q 'Container already set up' "$TEST_TMPDIR/run_ok.out" \
    || { echo "FAIL: rerun over a complete registration did not skip setup (exit $ec)"; cat "$TEST_TMPDIR/run_ok.out"; exit 1; }

# A short image already at the final name, as a copy cut short before
# babs_copy_image existed leaves, is replaced by a full copy.
mkdir -p "$TEST_TMPDIR/run_oldpartial"
head -c 10 /dev/zero > "$TEST_TMPDIR/run_oldpartial/app.sif"
run_case ok run_oldpartial app.sif CP_NO_FINAL=1
[ "$ec" -eq 0 ] || { echo "FAIL: rerun over a short app.sif exited $ec"; cat "$TEST_TMPDIR/run_oldpartial.out"; exit 1; }
[ "$(wc -c < "$TEST_TMPDIR/run_oldpartial/ants-ds/.datalad/environments/ants-container/image")" = 4096 ] \
    || { echo "FAIL: a short app.sif already in the run dir was registered"; exit 1; }

# A relative search directory that resolves to the run directory finds the
# destination itself: stop without deleting it.
mkdir -p "$TEST_TMPDIR/run_self"
head -c 4096 /dev/zero > "$TEST_TMPDIR/run_self/app.sif"
run_case ok run_self app.sif BASE_DIR=/nonexistent SIF_SEARCH_DIRS=.
expect_stop run_self "source inside the run directory" '^ERROR: the image was found in the run directory itself'
[ "$(wc -c < "$TEST_TMPDIR/run_self/app.sif")" = 4096 ] \
    || { echo "FAIL: the image found in the run directory was deleted"; exit 1; }

# A symlink in the run directory pointing at the source is replaced by a
# copy; the source is untouched.
mkdir -p "$TEST_TMPDIR/run_link"
ln -s "$BASE_DIR/app.sif" "$TEST_TMPDIR/run_link/app.sif"
run_case ok run_link
[ "$ec" -eq 0 ] || { echo "FAIL: a symlink to the source in the run dir stopped setup (exit $ec)"; cat "$TEST_TMPDIR/run_link.out"; exit 1; }
[ "$(wc -c < "$BASE_DIR/app.sif")" = 4096 ] || { echo "FAIL: the source behind a run-dir symlink changed"; exit 1; }

echo "PASS: test_image_copy"
