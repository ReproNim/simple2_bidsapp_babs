#!/bin/bash
# BABS Common Functions Library
# Sourced by ants_babs_script.sh, fs_babs_script.sh, mriqc_babs_script.sh

# Source .env if it exists
if [ -f ".env" ]; then
    source .env
fi

# Initialize run date - auto-generate YYMMDD or use RUN_DATE env var if set
babs_init_run_date() {
    if [ -z "${RUN_DATE:-}" ]; then
        RUN_DATE=$(date +%y%m%d)
    fi
    export RUN_DATE
    echo "Using RUN_DATE: $RUN_DATE"
}

# Set up logging - redirect all further output to a log file while still showing in console
# Usage: babs_setup_logging <scratch_dir> <app_name>
babs_setup_logging() {
    local scratch_dir="$1"
    local app_name="$2"

    # First-ever run of an app has no scratch dir yet, and this runs before
    # RUN_DIR is created -- without this, tee fails and the run has no log.
    mkdir -p "$scratch_dir"

    LOG_FILE="${scratch_dir}/babs_script_${RUN_DATE}_$(date +%Y%m%d_%H%M%S).log"
    echo "=== Script started at $(date) ===" | tee "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# Environment used on the LOGIN side (i.e. for `babs init`/`babs submit`).
# Must hold a BABS revision containing PennLINC/babs#369 (merged 2026-07, but in
# no PyPI release as of 0.5.4 -- install from git main): the configs here use
# the BIDS-study layout (analysis_path ".", inputs under sourcedata/), and any
# released babs silently produces the OLD project structure instead of erroring.
# Override with BABS_ENV if you install it elsewhere.
BABS_ENV="${BABS_ENV:-babs}"

# NIDM derivative to use as the augmentation source. `derivatives/nidm` does not
# exist in the satra study tree; the real shared resource is versioned.
# Override with BABS_NIDM_DERIV to point at a different NIDM release.
BABS_NIDM_DERIV="${BABS_NIDM_DERIV:-nidm_4.5.0}"

# Fail fast if the active babs cannot honour the BIDS-study layout keys the
# configs set. This is worth a hard check rather than a README line, because the
# failure is silent: babs 0.5.2's base.py hardcodes
#     self.analysis_path  = op.join(self.project_root, 'analysis')
#     self.input_ria_path = op.join(self.project_root, 'input_ria')
# and never reads them from the config, and nothing rejects the now-unknown keys.
# `babs init` then succeeds and quietly builds a LEGACY-layout project. Worse,
# the mistake stays hidden downstream, because a legacy project does have a
# top-level output_ria for a harvest script to find.
#
# Limitation: this compares the release triple only, so a hypothetical
# 0.5.5.devN predating PennLINC/babs#369 would pass. It catches the case that
# actually occurs -- an env still on 0.5.2.
babs_require_pr369() {
    local raw ver min="0.5.5"
    raw="$(babs --version 2>&1 | tail -1)"
    ver="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"

    if [ -z "$ver" ]; then
        echo "WARNING: could not parse a version from 'babs --version' (${raw})." >&2
        echo "  Skipping the PR#369 check -- verify the layout by hand." >&2
        return 0
    fi

    if [ "$(printf '%s\n%s\n' "$min" "$ver" | sort -V | head -1)" != "$min" ]; then
        echo "ERROR: babs ${ver} (env: ${BABS_ENV}) predates PennLINC/babs#369." >&2
        echo "  The configs here set analysis_path / input_ria_path /" >&2
        echo "  output_ria_path. This babs ignores them SILENTLY and would build a" >&2
        echo "  legacy-layout project instead -- no error, wrong result." >&2
        echo "  Install a babs >= ${min} and point BABS_ENV at it." >&2
        exit 1
    fi
}

# Set up environment - source bashrc, activate babs, load apptainer
babs_setup_env() {
    echo "Setting up environment..."
    source ~/.bashrc
    micromamba activate "$BABS_ENV"
    module load apptainer 2>/dev/null || true
    echo "Using BABS: $(babs --version 2>&1 | tail -1) (env: ${BABS_ENV})"
    babs_require_pr369
}

# Generic container setup
# Usage: babs_setup_container <app_name> <container_ds_name> <container_name> <sif_filename> [sif_alt_paths...]
babs_setup_container() {
    local app_name="$1"           # e.g., "ants", "fs", "mriqc"
    local container_ds_name="$2"  # e.g., "ants_bidsapp-container"
    local container_name="$3"     # e.g., "ants-nidm-bidsapp-0-1-0"
    local sif_filename="$4"       # e.g., "ants-nidm_bidsapp.sif"
    shift 4
    local sif_alt_paths=("$@")    # Alternative paths to search for SIF file

    # Check if container setup is already done
    if [ -d "${PWD}/${container_ds_name}" ] && \
       [ -f "${PWD}/${container_ds_name}/.datalad/config" ] && \
       grep -q "${container_name}" "${PWD}/${container_ds_name}/.datalad/config" 2>/dev/null; then
        echo "Container already set up, skipping container setup steps."
        return 0
    fi

    echo "Setting up container..."

    # Find and copy SIF file
    if [ ! -f "${PWD}/${sif_filename}" ]; then
        # Try BASE_DIR first
        if [ -f "${BASE_DIR}/${sif_filename}" ]; then
            echo "Copying ${sif_filename} from BASE_DIR"
            cp "${BASE_DIR}/${sif_filename}" .
        else
            # Try alternative paths
            for alt_path in "${sif_alt_paths[@]}"; do
                if [ -f "${alt_path}/${sif_filename}" ]; then
                    echo "Copying ${sif_filename} from ${alt_path}"
                    cp "${alt_path}/${sif_filename}" .
                    break
                fi
            done

            # If still not found, try with different SIF naming patterns
            if [ ! -f "${PWD}/${sif_filename}" ]; then
                for alt_path in "${sif_alt_paths[@]}"; do
                    # Check for files matching the app name pattern without date
                    for sif_file in "${alt_path}"/${app_name}*.sif; do
                        if [ -f "$sif_file" ]; then
                            echo "Copying $(basename "$sif_file") from ${alt_path} as ${sif_filename}"
                            cp "$sif_file" "./${sif_filename}"
                            break 2
                        fi
                    done
                done
            fi

            if [ ! -f "${PWD}/${sif_filename}" ]; then
                echo "ERROR: Cannot find container file. Please ensure ${sif_filename} exists in BASE_DIR or specified paths."
                exit 1
            fi
        fi
    fi

    # Create the container dataset if it doesn't exist
    if [ ! -d "${PWD}/${container_ds_name}" ]; then
        datalad create -D "${app_name} BIDS App" "${container_ds_name}"
    fi

    cd "${container_ds_name}" || exit 1

    # Add the container if it's not already added
    if ! datalad containers-list 2>/dev/null | grep -q "${container_name}"; then
        datalad containers-add \
            --url "${PWD}/../${sif_filename}" \
            "${container_name}"
    fi

    cd ../ || exit 1

    # Remove the SIF file if it exists
    if [ -f "${PWD}/${sif_filename}" ]; then
        rm -rf "${sif_filename}"
    fi
}

# Prepare YAML config - copy from template and substitute variables
# Usage: babs_prepare_yaml_config <template_path> <output_path> <subst_var1>=<value1> ...
babs_prepare_yaml_config() {
    local template_path="$1"
    local output_path="$2"
    shift 2

    if [ -f "$output_path" ]; then
        echo "Config file already exists at $output_path, skipping creation"
        return 0
    fi

    echo "Creating config YAML file from template..."

    # Copy template to output first
    cp "$template_path" "$output_path"

    # Perform substitutions using sed for more reliable pattern matching
    while [ $# -gt 0 ]; do
        local subst="$1"
        local var="${subst%%=*}"
        local value="${subst#*=}"

        # Escape only the characters that are special in a sed *replacement*:
        # backslash, ampersand, and the '/' delimiter. Regex metacharacters such
        # as '.' must NOT be escaped here (this is replacement text, not a
        # pattern) or they leak literal backslashes into the config, e.g.
        # "license.txt" -> "license\.txt". Escape backslash first.
        local escaped_value
        escaped_value=$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/\//\\\//g')

        # Replace both ${VAR} and $VAR forms
        sed -i "s/\${${var}}/${escaped_value}/g" "$output_path"
        sed -i "s/\$${var}/${escaped_value}/g" "$output_path"

        shift
    done

    echo "YAML config file created at $output_path"
}

# Add BABS's session placeholder only for session-wise projects. BABS defines
# $sesid in session job scripts, but not in subject job scripts.
# Usage: babs_configure_session_selection <config_path> <processing_level>
babs_configure_session_selection() {
    local config_path="$1"
    local processing_level="$2"

    if [ ! -f "$config_path" ]; then
        echo "ERROR: Config file not found: $config_path" >&2
        return 1
    fi

    # Make repeated wrapper runs deterministic if a generated config is reused.
    sed -i '/^[[:space:]]*\$SESSION_SELECTION_FLAG:/d' "$config_path"

    if [ "$processing_level" = "session" ]; then
        if ! grep -q '^[[:space:]]*\$SUBJECT_SELECTION_FLAG:' "$config_path"; then
            echo "ERROR: \$SUBJECT_SELECTION_FLAG not found in $config_path" >&2
            return 1
        fi
        sed -i \
            '/^[[:space:]]*\$SUBJECT_SELECTION_FLAG:/a\    $SESSION_SELECTION_FLAG: "--session-label"' \
            "$config_path"
    fi
}

# Resolve the NIDM input dataset for a dataset/site.
# Usage: babs_nidm_origin <dataset_name> <site_name>
babs_nidm_origin() {
    echo "${DATALAD_SET_DIR}/${1}/site-${2}/derivatives/${BABS_NIDM_DERIV}"
}

# Resolve the BABS project directory inside the study tree.
# The project must live beside the other derivatives (that is where the study
# layout expects results to land), NOT in scratch: scratch is only the compute
# space, and a project created there is invisible to anything reading the study.
# Usage: babs_study_output_dir <dataset_name> <site_name> <app_name>
babs_study_output_dir() {
    # BABS_OUTPUT_DIR wins when set: it places the project at an arbitrary path.
    # Renaming after `babs init` is not a simple `mv`: babs bakes absolute paths
    # into code/submit_job_template.yaml, so the final path has to be chosen up
    # front.
    if [ -n "${BABS_OUTPUT_DIR:-}" ]; then
        echo "$BABS_OUTPUT_DIR"
        return
    fi
    # Default is UNDATED: the project's own git history carries every date that
    # matters, and a date suffix in the folder name is what previously left the
    # study with parallel half-runs (babs-freesurfer-nidm_aug20 + _aug26) that
    # then had to be hand-merged and renamed. RUN_DATE still stamps the scratch
    # run dir, the compute space, the log file and the SLURM job name, which are
    # per-attempt rather than part of the deliverable. If a project already
    # exists here, `babs init` refuses -- deliberately: resuming or redoing a
    # site is a decision, made explicit via BABS_OUTPUT_DIR.
    echo "${DATALAD_SET_DIR}/${1}/site-${2}/derivatives/babs-${3}"
}

# Check NIDM directory for incremental building
# Usage: babs_check_nidm <dataset_name> <site_name>
babs_check_nidm() {
    local dataset_name="$1"
    local site_name="$2"
    local nidm_dir
    nidm_dir="$(babs_nidm_origin "$dataset_name" "$site_name")"

    # Per-subject layout: <nidm_deriv>/sub-<id>/nidm.ttl (there is no nidm.ttl at
    # the derivative root, so checking for one there always reported "not found").
    if [ -d "$nidm_dir" ] && compgen -G "${nidm_dir}/sub-*/nidm.ttl" >/dev/null; then
        local n
        n=$(compgen -G "${nidm_dir}/sub-*/nidm.ttl" | wc -l)
        echo "Found NIDM at $nidm_dir (${n} subject file(s)) - NIDM will be built incrementally"
    else
        echo "No NIDM found at $nidm_dir - NIDM will be created from scratch"
    fi
}

# Initialize BABS and submit jobs
# Usage: babs_init_and_submit <container_ds_path> <container_name> <config_path> <output_dir> <processing_level>
babs_init_and_submit() {
    local container_ds_path="$1"
    local container_name="$2"
    local config_path="$3"
    local output_dir="$4"
    local processing_level="${5:-subject}"

    echo "Initializing BABS with the dataset-specific output directory..."

    # Optional pilot / re-run subset: set BABS_LIST_SUB_FILE to a CSV with a
    # 'sub_id' column (plus 'ses_id' for session-level projects) to restrict the
    # project to those subjects. Unset means "every subject in the input".
    local list_sub_args=()
    if [ -n "${BABS_LIST_SUB_FILE:-}" ]; then
        if [ ! -f "$BABS_LIST_SUB_FILE" ]; then
            echo "ERROR: BABS_LIST_SUB_FILE not found: $BABS_LIST_SUB_FILE" >&2
            exit 1
        fi
        echo "Restricting project to subjects listed in $BABS_LIST_SUB_FILE:"
        cat "$BABS_LIST_SUB_FILE"
        list_sub_args=( --list_sub_file "$BABS_LIST_SUB_FILE" )
    fi

    babs init \
        --container_ds "${container_ds_path}" \
        --container_name "${container_name}" \
        --container_config "${config_path}" \
        --processing_level "${processing_level}" \
        --queue slurm \
        ${list_sub_args[@]+"${list_sub_args[@]}"} \
        "${output_dir}"

    cd "${output_dir}" || exit 1

    # Check the setup before submitting.
    #
    # NOTE: `babs check-setup` currently crashes on the PR #369 BIDS-study layout
    # (analysis_path=".", inputs under sourcedata/). check_setup.py hardcodes a
    # pre-check on `<analysis_path>/inputs/data` that does not exist in that
    # layout, raising FileNotFoundError before it reaches the real per-input-
    # dataset validation. That pre-check is redundant with the per-dataset loop
    # that follows it, so bypassing check-setup does not lose validation of the
    # input datasets themselves.
    #
    # It DOES cost something, though, and not just dataset checks: `--job_test`
    # is documented in babs as "Whether to submit and run a test job", so
    # skipping it skips a real sbatch submission with this config's
    # cluster_resources. That is not hypothetical -- the ants config once asked
    # for --time=18:00:00 against mit_normal's 12h cap, which sbatch rejects
    # outright, and with this flag set the project built completely and then
    # submitted nothing. A test job would have surfaced it at setup time.
    #
    # So: use it to work around the upstream crash, not as a default. Set
    # BABS_SKIP_CHECK_SETUP=1 for study-layout projects until babs fixes
    # check_setup.py upstream.
    local check_setup_ok=0
    if [ "${BABS_SKIP_CHECK_SETUP:-0}" = "1" ]; then
        echo "BABS_SKIP_CHECK_SETUP=1: skipping 'babs check-setup'"
        echo "  (works around babs check_setup.py hardcoded 'inputs/data' check"
        echo "   that is incompatible with the PR #369 BIDS-study layout)."
        check_setup_ok=1
    else
        echo "Checking BABS setup..."
        if babs check-setup "${PWD}" --job_test; then
            check_setup_ok=1
        fi
    fi

    # Optional controlled ramp: set BABS_SUBMIT_COUNT=N to submit only the first
    # N jobs. Use it when an app's memory/wall-clock needs are still unverified --
    # measure MaxRSS/Elapsed from the first completions, size cluster_resources
    # from real data, then `babs submit` the rest into the same project. Unset
    # means "submit every remaining job".
    local submit_args=()
    if [ -n "${BABS_SUBMIT_COUNT:-}" ]; then
        if ! [[ "$BABS_SUBMIT_COUNT" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: BABS_SUBMIT_COUNT must be a positive integer (got '$BABS_SUBMIT_COUNT')" >&2
            exit 1
        fi
        submit_args=( --count "$BABS_SUBMIT_COUNT" )
    fi

    if [ "$check_setup_ok" -eq 1 ]; then
        if [ -n "${BABS_SUBMIT_COUNT:-}" ]; then
            echo "Submitting first ${BABS_SUBMIT_COUNT} job(s) (BABS_SUBMIT_COUNT set)..."
            echo "  Submit the rest later with: babs submit \"${output_dir}\""
        else
            echo "Submitting all jobs..."
        fi
        babs submit ${submit_args[@]+"${submit_args[@]}"}
    else
        echo "BABS setup check failed. Please review the errors above."
        echo "If this is the known study-layout check_setup bug (FileNotFoundError"
        echo "on '<project>/inputs/data'), re-run with BABS_SKIP_CHECK_SETUP=1."
        echo "Or submit manually after review with: babs submit"
        exit 1
    fi
}

# Print completion message
# Usage: babs_print_completion <output_dir>
babs_print_completion() {
    local output_dir="$1"
    echo "=== Script completed at $(date) ===" | tee -a "$LOG_FILE"
    echo "Output directory: $output_dir" | tee -a "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
}

# Print usage and examples to stderr. Call after an "ERROR: ..." line in any
# arg-handling failure path so users see a consistent message.
babs_print_usage() {
    echo "  Usage: $0 <site_name> <dataset_name> [processing_level]" >&2
    echo "    processing_level: 'subject' (default) or 'session'" >&2
    echo "  Example: $0 Caltech study-ABIDE subject" >&2
    echo "  Example: $0 Brown study-ADHD200 session" >&2
}

# Validate arguments
# Usage: babs_validate_args <site_name> <dataset_name> <processing_level>
# processing_level must be "subject" or "session" (no empty allowed; callers
# should default to "subject" before passing in).
babs_validate_args() {
    local site_name="$1"
    local dataset_name="$2"
    local processing_level="$3"

    if [ -z "$site_name" ] || [ -z "$dataset_name" ]; then
        echo "ERROR: Missing arguments." >&2
        babs_print_usage
        exit 1
    fi

    if [ "$processing_level" != "subject" ] && [ "$processing_level" != "session" ]; then
        echo "ERROR: processing_level must be either 'subject' or 'session' (provided: '$processing_level')" >&2
        babs_print_usage
        exit 1
    fi
}

# Parse positional arguments for the wrapper scripts.
# Sets globals: SITE_NAME, DATASET_NAME, PROCESSING_LEVEL.
# Usage: babs_parse_args "$@"
babs_parse_args() {
    if [ "$#" -gt 3 ]; then
        echo "ERROR: Too many arguments ($#)." >&2
        babs_print_usage
        exit 1
    fi

    SITE_NAME="$1"
    DATASET_NAME="$2"
    PROCESSING_LEVEL="${3:-subject}"

    babs_validate_args "$SITE_NAME" "$DATASET_NAME" "$PROCESSING_LEVEL"
}
