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
cat > "$STUBS/cp" <<STUB
#!/bin/bash
case "\${CP_MODE:-ok}" in
    ok) exec "$REAL_CP" "\$@" ;;
    fail) head -c 10 "\$1" > "\$2"; exit 1 ;;
    short) head -c 10 "\$1" > "\$2"; exit 0 ;;
    kill) head -c 10 "\$1" > "\$2"; kill -9 \$PPID ;;
esac
STUB
chmod +x "$STUBS/cp"

# datalad stand-in: reaching containers-add means the image was accepted.
cat > "$STUBS/datalad" <<'STUB'
#!/bin/bash
echo "datalad $*" >> "$STUB_DIR/calls.log"
case "$1" in create) mkdir -p "${@: -1}" ;; esac
exit 0
STUB
chmod +x "$STUBS/datalad"

export STUB_DIR="$TEST_TMPDIR"
export BASE_DIR="$TEST_TMPDIR/images"
mkdir -p "$BASE_DIR"
head -c 4096 /dev/zero > "$BASE_DIR/app.sif"

# run_case <mode> <dir>: run the function in a subshell, as it can `exit`.
run_case() {
    local mode="$1" dir="$TEST_TMPDIR/$2"
    mkdir -p "$dir"
    : > "$TEST_TMPDIR/calls.log"
    set +e
    (
        cd "$dir"
        PATH="$STUBS:$PATH" CP_MODE="$mode"
        export PATH CP_MODE
        source "$REPO_ROOT/babs_common.sh"
        babs_log_image_revision() { :; }
        babs_setup_container ants ants-ds ants-container app.sif
    ) > "$dir.out" 2>&1
    ec=$?
    set -e
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

# A stale .partial from an earlier killed run does not block a fresh copy.
mkdir -p "$TEST_TMPDIR/run_stale"
echo stale > "$TEST_TMPDIR/run_stale/app.sif.partial"
run_case ok run_stale
[ "$ec" -eq 0 ] || { echo "FAIL: stale .partial blocked the copy"; exit 1; }
grep -q containers-add "$TEST_TMPDIR/calls.log" \
    || { echo "FAIL: copy after a stale .partial did not reach containers-add"; exit 1; }
[ ! -e "$TEST_TMPDIR/run_stale/app.sif.partial" ] \
    || { echo "FAIL: stale .partial was left behind"; exit 1; }

# A complete copy goes through to containers-add.
run_case ok run_ok
[ "$ec" -eq 0 ] || { echo "FAIL: complete copy exited $ec"; cat "$TEST_TMPDIR/run_ok.out"; exit 1; }
grep -q containers-add "$TEST_TMPDIR/calls.log" \
    || { echo "FAIL: complete copy did not reach containers-add"; exit 1; }

echo "PASS: test_image_copy"
