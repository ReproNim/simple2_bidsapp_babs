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

    LOG_FILE="${scratch_dir}/babs_script_${RUN_DATE}_$(date +%Y%m%d_%H%M%S).log"
    echo "=== Script started at $(date) ===" | tee "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
}

# Set up environment - source bashrc, activate babs, load apptainer
babs_setup_env() {
    echo "Setting up environment..."
    source ~/.bashrc
    micromamba activate babs
    module load apptainer 2>/dev/null || true
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

    # Create output with variable substitutions
    local content
    content=$(cat "$template_path")

    while [ $# -gt 0 ]; do
        local subst="$1"
        local var="${subst%%=*}"
        local value="${subst#*=}"
        content="${content//\${${var}}/${value}}"
        content="${content//\$${var}/${value}}"
        shift
    done

    echo "$content" > "$output_path"
    echo "YAML config file created at $output_path"
}

# Check NIDM directory for incremental building
# Usage: babs_check_nidm <dataset_name> <site_name>
babs_check_nidm() {
    local dataset_name="$1"
    local site_name="$2"
    local nidm_dir="${DATALAD_SET_DIR}/${dataset_name}/site-${site_name}/derivatives/nidm"

    if [ -d "$nidm_dir" ] && [ -f "$nidm_dir/nidm.ttl" ]; then
        echo "Found NIDM directory at $nidm_dir - NIDM will be built incrementally"
    else
        echo "No NIDM directory found - NIDM will be created from scratch"
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

    babs init \
        --container_ds "${container_ds_path}" \
        --container_name "${container_name}" \
        --container_config "${config_path}" \
        --processing_level "${processing_level}" \
        --queue slurm \
        "${output_dir}"

    cd "${output_dir}" || exit 1

    # Optional: First check the setup before submitting
    echo "Checking BABS setup..."
    babs check-setup "${PWD}" --job_test

    # If babs check-setup is successful, submit all jobs
    if [ $? -eq 0 ]; then
        echo "BABS setup check successful, submitting all jobs..."
        babs submit
    else
        echo "BABS setup check failed. Please review the errors above."
        echo "You can manually submit after fixing issues with: babs submit --all"
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

# Validate arguments
# Usage: babs_validate_args <site_name> <dataset_name>
babs_validate_args() {
    local site_name="$1"
    local dataset_name="$2"

    if [ -z "$site_name" ] || [ -z "$dataset_name" ]; then
        echo "Error: Missing arguments. Usage: $0 <site_name> <dataset_name>"
        exit 1
    fi
}
