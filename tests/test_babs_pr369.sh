#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

cd "$REPO_ROOT"
source "$REPO_ROOT/babs_common.sh"

for template in "$REPO_ROOT"/config_*-nidm.yaml; do
    config_path="$TEST_TMPDIR/$(basename "$template")"
    babs_prepare_yaml_config \
        "$template" \
        "$config_path" \
        "BIDS_ORIGIN=/tmp/BIDS" \
        "NIDM_ORIGIN=/tmp/NIDM" \
        "COMPUTE_SPACE=/tmp/compute" \
        "RUN_DATE=260722"

    grep -q '^analysis_path: "\."$' "$config_path"
    grep -q '^input_ria_path: "\.babs/input_ria"$' "$config_path"
    grep -q '^output_ria_path: "\.babs/output_ria"$' "$config_path"
    grep -q 'path_in_babs: sourcedata/BIDS' "$config_path"
    grep -q 'path_in_babs: sourcedata/NIDM' "$config_path"

    # The per-subject zip scheme depends on ${subid} SURVIVING templating:
    # babs_prepare_yaml_config only substitutes the vars passed to it, so
    # ${subid} must reach the rendered participant_job.sh where bash expands it
    # per job. If a future change ever substitutes it, every job would zip the
    # same literal folder name and the subjects would collide again.
    grep -q '^[[:space:]]*\${subid}: ' "$config_path"

    babs_configure_session_selection "$config_path" subject
    if grep -q '^[[:space:]]*\$SESSION_SELECTION_FLAG:' "$config_path"; then
        echo "Session selection leaked into subject config: $config_path" >&2
        exit 1
    fi

    babs_configure_session_selection "$config_path" session
    test "$(grep -c '^[[:space:]]*\$SESSION_SELECTION_FLAG: "--session-label"$' "$config_path")" -eq 1

    # Reconfiguration must be idempotent.
    babs_configure_session_selection "$config_path" session
    test "$(grep -c '^[[:space:]]*\$SESSION_SELECTION_FLAG: "--session-label"$' "$config_path")" -eq 1
done

echo "BABS PR #369 configuration checks passed"
