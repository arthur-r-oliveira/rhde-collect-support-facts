#!/bin/bash

# --- Configuration Variables ---
# Base directory where reports will be saved on the local machine
# This directory will contain a timestamped subdirectory for each run.
LOCAL_COLLECTION_BASE_DIR="/var/tmp/collected_microshift_reports"

# The kubeconfig file path that 'oc' commands should use.
# IMPORTANT: Adjust this path if your MicroShift kubeconfig is in a different location.
MICROSHIFT_KUBECONFIG_PATH="/var/lib/microshift/resources/kubeadmin/kubeconfig"

# --- Script Logic ---

echo "Starting MicroShift report collection..."

# Get current timestamp for unique directory naming
CURRENT_TIMESTAMP=$(date +%Y%m%d%H%M%S)
REPORT_DIR="${LOCAL_COLLECTION_BASE_DIR}/${CURRENT_TIMESTAMP}"

echo "Reports will be saved in: ${REPORT_DIR}"

# 1. Create the local collection directory
if ! mkdir -p "${REPORT_DIR}"; then
    echo "ERROR: Failed to create report directory: ${REPORT_DIR}"
    exit 1
fi
echo "Created report directory: ${REPORT_DIR}"

# --- Verify Kubeconfig Permissions and Existence ---
if [ ! -f "${MICROSHIFT_KUBECONFIG_PATH}" ]; then
    echo "ERROR: Kubeconfig file not found at: ${MICROSHIFT_KUBECONFIG_PATH}"
    echo "Please ensure the path is correct and the file exists."
    # Attempt to use default KUBECONFIG if specified path doesn't exist.
    # This might not be suitable for MicroShift, but as a fallback.
    # If this is a critical error, you might want to exit here.
    exit 1
fi

# Check read permissions for the current user (which will be root if running with sudo)
if [ ! -r "${MICROSHIFT_KUBECONFIG_PATH}" ]; then
    echo "ERROR: Current user (root) does not have read permissions for kubeconfig: ${MICROSHIFT_KUBECONFIG_PATH}"
    echo "Please adjust file permissions (e.g., 'sudo chmod o+r ${MICROSHIFT_KUBECONFIG_PATH}' or 'sudo chmod a+r ${MICROSHIFT_KUBECONFIG_PATH}')"
    exit 1
fi

# Set KUBECONFIG environment variable for 'oc' commands
export KUBECONFIG="${MICROSHIFT_KUBECONFIG_PATH}"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 2. Collect microshift-sos-report
# Corrected usage for microshift-sos-report based on your error message
SOS_REPORT_FILE_PATTERN="${REPORT_DIR}/sosreport-microshift-*.tar.xz"
if ls "${SOS_REPORT_FILE_PATTERN}" 1> /dev/null 2>&1; then
    echo "MicroShift SOS report already exists in ${REPORT_DIR}. Skipping sos report collection."
else
    echo "Collecting microshift-sos-report..."
    # The command expects --tmp-dir, and the report is placed there.
    if microshift-sos-report --tmp-dir "${LOCAL_COLLECTION_BASE_DIR}"; then
        echo "MicroShift SOS report collected to temporary location."
        # Find the generated sos report archive in the temporary directory
        GENERATED_SOS_REPORT=$(find "${SOS_TMP_DIR}" -maxdepth 1 -name "sosreport*.tar.xz")
        if [ -n "${GENERATED_SOS_REPORT}" ]; then
            mv "${GENERATED_SOS_REPORT}" "${REPORT_DIR}/"
            echo "Moved SOS report to: ${REPORT_DIR}/"
        else
            echo "WARNING: Could not find generated sosreport in temporary directory: ${SOS_TMP_DIR}"
        fi
    else
        echo "WARNING: microshift-sos report failed. Continuing with other tasks."
    fi
fi


# 3. Get list of all application namespaces
echo "Getting list of application namespaces..."
# Filter out common system namespaces
# We need to make sure oc commands are working now.
APP_NAMESPACES=$(oc get ns|egrep -v "NAME|openshift|kube|default"|awk '{print $1}')

if [ -z "${APP_NAMESPACES}" ]; then
    echo "No application namespaces found or 'oc' command failed to list them."
    declare -a NAMESPACE_ARRAY=() # Initialize empty array
else
    # Convert space-separated string to array
    read -r -a NAMESPACE_ARRAY <<< "${APP_NAMESPACES}"
    echo "Found application namespaces: ${NAMESPACE_ARRAY[*]}"
fi

# 4. Run oc adm inspect for each application namespace
OC_INSPECT_COLLECTED=false # Flag to track if any oc inspect reports were generated
if [ ${#NAMESPACE_ARRAY[@]} -gt 0 ]; then
    echo "Running 'oc adm inspect' for each application namespace..."
    for NS in "${NAMESPACE_ARRAY[@]}"; do
        echo "  - Inspecting namespace: ${NS}"
        # --dest-dir will create subdirectories within REPORT_DIR
        if oc adm inspect "ns/${NS}" --dest-dir="${REPORT_DIR}"; then
            echo "    Successfully inspected namespace: ${NS}"
            OC_INSPECT_COLLECTED=true
        else
            echo "    WARNING: 'oc adm inspect' failed for namespace '${NS}'. Continuing."
        fi
    done
    echo "'oc adm inspect' collection complete."
else
    echo "Skipping 'oc adm inspect' as no application namespaces were found."
fi

# 5. Compress all collected oc adm inspect directories
OC_INSPECT_ARCHIVE="${REPORT_DIR}/oc_adm_inspect_reports_${CURRENT_TIMESTAMP}.tar.gz"
echo "Compressing 'oc adm inspect' reports..."

# Only attempt to tar if at least one oc inspect report was successfully collected
if [ "${OC_INSPECT_COLLECTED}" = true ]; then
    # Find all directories created by oc adm inspect that are not the sosreport itself
    # We explicitly list directories to ensure tar doesn't complain about empty input
    INSPECT_DIRS=$(find "${REPORT_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0)
    # Check if any directories were found by find
    if [ -n "${INSPECT_DIRS}" ]; then
        # Use find -exec or a loop if xargs with tar is problematic on some systems for specific args
        # Or, a simpler tar command targeting the REPORT_DIR and excluding known archives
        tar -czf "${OC_INSPECT_ARCHIVE}" -C "${REPORT_DIR}" . --exclude='sosreport-microshift-*.tar.xz' --exclude='oc_adm_inspect_reports_*.tar.gz'
        if [ $? -ne 0 ]; then
            echo "WARNING: Failed to compress 'oc adm inspect' reports. Tar exit code: $?"
        else
            echo "Compressed 'oc adm inspect' reports to: ${OC_INSPECT_ARCHIVE}"
        fi
    else
        echo "No 'oc adm inspect' directories found to compress."
    fi
else
    echo "Skipping compression of 'oc adm inspect' reports as none were collected."
fi


echo ""
echo "--------------------------------------------------------"
echo "Report collection complete."
echo "All collected reports are located in: ${REPORT_DIR}"
echo "--------------------------------------------------------"

# Optional: Unset KUBECONFIG to avoid affecting subsequent shell commands
unset KUBECONFIG
