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

# --max-voxel-size: a reused config must end up with exactly the current
# setting, never a stale one from an earlier run.
config_path="$TEST_TMPDIR/config_mriqc-nidm.yaml"
count_voxel_lines() { grep -c '^[[:space:]]*--max-voxel-size:' "$config_path" || true; }
babs_configure_max_voxel_size "$config_path" 2 0.1.3
test "$(grep -c '^    --max-voxel-size: "2"$' "$config_path")" -eq 1
babs_configure_max_voxel_size "$config_path" 3 0.1.3
test "$(count_voxel_lines)" -eq 1
grep -q '^    --max-voxel-size: "3"$' "$config_path"
babs_configure_max_voxel_size "$config_path" "" 0.1.3
test "$(count_voxel_lines)" -eq 0
for bad in 0 00 0.0 -1 2mm abc; do
    if babs_configure_max_voxel_size "$config_path" "$bad" 0.1.3 2>/dev/null; then
        echo "MRIQC_MAX_VOXEL_SIZE='$bad' was accepted" >&2
        exit 1
    fi
done
if babs_configure_max_voxel_size "$config_path" 2 0.1.2 2>/dev/null; then
    echo "--max-voxel-size was accepted for mriqc-nidm 0.1.2" >&2
    exit 1
fi
babs_configure_max_voxel_size "$config_path" 1.5 0.1.10
grep -q '^    --max-voxel-size: "1.5"$' "$config_path"
test "$(count_voxel_lines)" -eq 1

echo "BABS PR #369 configuration checks passed"
