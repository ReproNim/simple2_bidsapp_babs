#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# babs_common.sh sources ./.env when there is one. Start in the temp dir so
# the result does not depend on a .env in the repo root.
cd "$TEST_TMPDIR"
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

# --max-voxel-size: a config that already holds a limit must end up with exactly the current
# setting, never a second line.
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

# Without the line it inserts after, it must fail instead of dropping the limit.
no_anchor="$TEST_TMPDIR/config_no_anchor.yaml"
grep -v '^[[:space:]]*\$SUBJECT_SELECTION_FLAG:' "$config_path" > "$no_anchor"
if babs_configure_max_voxel_size "$no_anchor" 2 0.1.3 2>/dev/null; then
    echo "--max-voxel-size was accepted without \$SUBJECT_SELECTION_FLAG" >&2
    exit 1
fi

# babs_check_zip_version: the rendered config must zip under this run's version.
# The check exits on a mismatch, so each call runs in a subshell.
zip_check() {  # <ZIP_VERSION> <config>
    ( ZIP_VERSION="$1"; babs_check_zip_version "$2" ANTS_VERSION ) >/dev/null 2>&1
}
zip_config="$TEST_TMPDIR/zip_config.yaml"
write_zip_config() {  # <value of an unrelated option> <zip version>
    printf '%s\n' \
        'bids_app_args:' \
        '    --skip-bids-validation: ""' \
        "    --some-option: \"$1\"" \
        'zip_foldernames:' \
        "    \${subid}: \"$2\"" > "$zip_config"
}
zip_failures=0
write_zip_config other 0-2-2
if ! zip_check 0-2-2 "$zip_config"; then
    echo "a config zipping as 0-2-2 was rejected for ZIP_VERSION=0-2-2" >&2
    zip_failures=$((zip_failures + 1))
fi
if zip_check 0-2-3 "$zip_config"; then
    echo "a config zipping as 0-2-2 was accepted for ZIP_VERSION=0-2-3" >&2
    zip_failures=$((zip_failures + 1))
fi
# A wrapper that never resolved its version has an empty ZIP_VERSION. The
# config rendered with it zips as "", and other options hold "" too, so an
# empty version must not count as a match.
if zip_check "" "$zip_config"; then
    echo "an empty ZIP_VERSION was accepted" >&2
    zip_failures=$((zip_failures + 1))
fi
write_zip_config other ""
if zip_check "" "$zip_config"; then
    echo "an empty ZIP_VERSION was accepted for a config with an empty zip version" >&2
    zip_failures=$((zip_failures + 1))
fi
# The version has to be the one on the zip line, not any quoted value.
write_zip_config 0-2-3 0-2-2
if zip_check 0-2-3 "$zip_config"; then
    echo "ZIP_VERSION=0-2-3 was accepted because another option holds \"0-2-3\"" >&2
    zip_failures=$((zip_failures + 1))
fi
# The remaining cases write the config lines directly.
write_zip_lines() { printf '%s\n' 'bids_app_args:' '    --skip-bids-validation: ""' "$@" > "$zip_config"; }
# A comment after the value is the same YAML.
write_zip_lines 'zip_foldernames:' '    ${subid}: "0-2-2"  # the version that ran'
if ! zip_check 0-2-2 "$zip_config"; then
    echo "a zip line with a trailing comment was rejected" >&2
    zip_failures=$((zip_failures + 1))
fi
# YAML keeps the last of two equal keys, so two ${subid} lines leave it open
# which version babs zips under: neither may be accepted.
write_zip_lines '    ${subid}: "0-2-3"' 'zip_foldernames:' '    ${subid}: "0-2-2"'
for v in 0-2-3 0-2-2; do
    if zip_check "$v" "$zip_config"; then
        echo "ZIP_VERSION=$v was accepted for a config with two \${subid} lines" >&2
        zip_failures=$((zip_failures + 1))
    fi
done
# The same holds when the second key is written with quotes.
write_zip_lines 'zip_foldernames:' '    ${subid}: "0-2-2"' '    "${subid}": "0-2-3"'
if zip_check 0-2-2 "$zip_config"; then
    echo "ZIP_VERSION=0-2-2 was accepted although a quoted \"\${subid}\" key holds 0-2-3" >&2
    zip_failures=$((zip_failures + 1))
fi
# A commented-out zip line is not the zip line.
write_zip_lines 'zip_foldernames:' '    # ${subid}: "0-2-3"' '    ${subid}: "0-2-2"'
if zip_check 0-2-3 "$zip_config"; then
    echo "ZIP_VERSION=0-2-3 was accepted from a commented-out zip line" >&2
    zip_failures=$((zip_failures + 1))
fi
if ! zip_check 0-2-2 "$zip_config"; then
    echo "a commented-out zip line made the live one be rejected" >&2
    zip_failures=$((zip_failures + 1))
fi
# No zip line at all.
write_zip_lines 'zip_foldernames:'
if zip_check 0-2-2 "$zip_config"; then
    echo "a config with no \${subid} line was accepted" >&2
    zip_failures=$((zip_failures + 1))
fi
# ZIP_VERSION has to be X-Y-Z, even when the config holds the same string.
for v in 0.2.2 0-2 0-2-2rc1; do
    write_zip_lines 'zip_foldernames:' "    \${subid}: \"$v\""
    if zip_check "$v" "$zip_config"; then
        echo "ZIP_VERSION=$v, which is not X-Y-Z, was accepted" >&2
        zip_failures=$((zip_failures + 1))
    fi
done
test "$zip_failures" -eq 0

echo "BABS PR #369 configuration checks passed"
