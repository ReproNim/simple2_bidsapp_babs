#!/usr/bin/env bash
# Positional-argument handling shared by the three wrappers:
# babs_parse_args and babs_validate_args in babs_common.sh. Both call `exit 1`
# on a bad argument, so each case runs in its own bash process, as it does in
# a wrapper. Nothing here needs babs, datalad or a .env.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# babs_common.sh sources ./.env when there is one. Start in the temp dir so
# the result does not depend on a .env in the repo root.
cd "$TEST_TMPDIR"

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

# run_case <function> [args...]: source babs_common.sh in a fresh shell, call
# the function, then print the three globals. Sets STATUS and OUTPUT (stdout
# and stderr together). A function that exits never reaches the printf. The
# shell starts from an empty environment, so neither exported SITE_NAME,
# DATASET_NAME or PROCESSING_LEVEL nor a BASH_ENV of the caller reaches it.
run_case() {
    STATUS=0
    OUTPUT=$(env -i PATH=/usr/bin:/bin bash -c '
        source "$1/babs_common.sh"
        fn="$2"; shift 2
        "$fn" "$@"
        printf "RESULT site=[%s] dataset=[%s] level=[%s]\n" \
            "${SITE_NAME-unset}" "${DATASET_NAME-unset}" "${PROCESSING_LEVEL-unset}"
    ' _ "$REPO_ROOT" "$@" 2>&1) || STATUS=$?
}

# expect_error <label> <message fragment> <function> [args...]
expect_error() {
    local label="$1" fragment="$2"
    shift 2
    run_case "$@"
    if [[ "$OUTPUT" == *"RESULT"* ]]; then
        fail "$label: the function returned instead of exiting:
$OUTPUT"
    elif [ "$STATUS" -ne 1 ]; then
        fail "$label: exit $STATUS, expected 1:
$OUTPUT"
    elif [[ "$OUTPUT" != *"ERROR: ${fragment}"* ]]; then
        fail "$label: no 'ERROR: ${fragment}' in:
$OUTPUT"
    elif [[ "$OUTPUT" != *"Usage:"* ]]; then
        fail "$label: the error did not print the Usage: line:
$OUTPUT"
    fi
}

# expect_ok <label> <site> <dataset> <level> <function> [args...]
expect_ok() {
    local label="$1" site="$2" dataset="$3" level="$4"
    shift 4
    run_case "$@"
    if [ "$STATUS" -ne 0 ]; then
        fail "$label: exit $STATUS, expected 0:
$OUTPUT"
    elif [[ "$OUTPUT" == *"ERROR"* ]]; then
        fail "$label: printed an error:
$OUTPUT"
    elif [ "$OUTPUT" != "RESULT site=[$site] dataset=[$dataset] level=[$level]" ]; then
        fail "$label: globals were not set to site=$site dataset=$dataset level=$level:
$OUTPUT"
    fi
}

# --- babs_parse_args: argument count -----------------------------------------
expect_error "no arguments" "Missing arguments." babs_parse_args
expect_error "site only" "Missing arguments." babs_parse_args Caltech
expect_error "empty site" "Missing arguments." babs_parse_args "" study-ABIDE
expect_error "empty dataset" "Missing arguments." babs_parse_args Caltech ""
expect_error "four arguments" "Too many arguments (4)." babs_parse_args Caltech study-ABIDE subject extra
expect_error "five arguments" "Too many arguments (5)." babs_parse_args Caltech study-ABIDE subject extra more
# The count is checked before the values, so an empty fourth argument still counts.
expect_error "empty fourth argument" "Too many arguments (4)." babs_parse_args Caltech study-ABIDE subject ""

# --- babs_parse_args: processing level ---------------------------------------
expect_error "invalid level" "processing_level must be either 'subject' or 'session' (provided: 'run')" \
    babs_parse_args Caltech study-ABIDE run
expect_error "level is case-sensitive" "processing_level must be either 'subject' or 'session' (provided: 'Subject')" \
    babs_parse_args Caltech study-ABIDE Subject
# An explicit empty level defaults to subject too (${3:-subject}), as an omitted one does.
expect_ok "empty level defaults to subject" Caltech study-ABIDE subject babs_parse_args Caltech study-ABIDE ""

# --- babs_parse_args: names go into paths ------------------------------------
for bad in "a/b" "a b" "../x" "-x" ".x" "_x" 'a$b' "a;b"; do
    expect_error "site '$bad'" "site and dataset names must start with a letter or digit" \
        babs_parse_args "$bad" study-ABIDE subject
    expect_error "dataset '$bad'" "site and dataset names must start with a letter or digit" \
        babs_parse_args Caltech "$bad" subject
done

# --- babs_parse_args: valid calls set the globals ----------------------------
expect_ok "two arguments default to subject" Caltech study-ABIDE subject babs_parse_args Caltech study-ABIDE
expect_ok "subject" Caltech study-ABIDE subject babs_parse_args Caltech study-ABIDE subject
expect_ok "session" Brown study-ADHD200 session babs_parse_args Brown study-ADHD200 session
expect_ok "dots, underscores, hyphens, digits" site_1.b study-2.0_x subject \
    babs_parse_args site_1.b study-2.0_x subject
expect_ok "leading digit" 9site 1study session babs_parse_args 9site 1study session

# --- babs_validate_args directly ---------------------------------------------
expect_error "validate: missing site" "Missing arguments." babs_validate_args "" study-ABIDE subject
expect_error "validate: missing dataset" "Missing arguments." babs_validate_args Caltech "" subject
expect_error "validate: bad name" "site and dataset names must start with a letter or digit" \
    babs_validate_args "a/b" study-ABIDE subject
# Unlike babs_parse_args, it does not default the level.
expect_error "validate: empty level" "processing_level must be either 'subject' or 'session' (provided: '')" \
    babs_validate_args Caltech study-ABIDE ""
expect_error "validate: invalid level" "processing_level must be either 'subject' or 'session' (provided: 'x')" \
    babs_validate_args Caltech study-ABIDE x
# It returns 0 and leaves the globals alone.
expect_ok "validate: subject" unset unset unset babs_validate_args Caltech study-ABIDE subject
expect_ok "validate: session" unset unset unset babs_validate_args Caltech study-ABIDE session

if [ "$failures" -ne 0 ]; then
    echo "$failures argument-parsing check(s) failed" >&2
    exit 1
fi
echo "Argument-parsing checks passed"
