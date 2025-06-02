#!/bin/bash

# --- Configuration Variables ---
# Base directory where reports will be saved on the local machine
# This directory will contain a timestamped subdirectory for each run.
LOCAL_COLLECTION_BASE_DIR="./collected_microshift_reports"

# The kubeconfig file path that 'oc' commands should use.
# IMPORTANT: Adjust this path if your MicroShift kubeconfig is in a different location.
MICROSHIFT_KUBECONFIG_PATH="/var/lib/microshift/resources/kubeconfig"

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

# Set KUBECONFIG environment variable for 'oc' commands
export KUBECONFIG="${MICROSHIFT_KUBECONFIG_PATH}"
echo "KUBECONFIG set to: ${KUBECONFIG}"

# 2. Collect microshift-sos-report
SOS_REPORT_FILE_PATTERN="${REPORT_DIR}/sosreport-microshift-*.tar.xz"
if ls "${SOS_REPORT_FILE_PATTERN}" 1> /dev/null 2>&1; then
    echo "MicroShift SOS report already exists in ${REPORT_DIR}. Skipping sos report collection."
else
    echo "Collecting microshift-sos-report..."
    if ! microshift-sos report -o "${REPORT_DIR}"; then
        echo "WARNING: microshift-sos report failed. Continuing with other tasks."
    else
        echo "MicroShift SOS report collected."
    fi
fi

# 3. Get list of all application namespaces
echo "Getting list of application namespaces..."
# Filter out common system namespaces
APP_NAMESPACES=$(oc get namespaces -o jsonpath='{.items[?(@.metadata.labels.kubernetes\.io/metadata\.name!="kube-system" && @.metadata.labels.kubernetes\.io/metadata\.name!="openshift" && @.metadata.labels.kubernetes\.io/metadata\.name!="default" && @.metadata.labels.kubernetes\.io/metadata\.name!="kube-public" && @.metadata.labels.kubernetes\.io/metadata\.name!="kube-node-lease")].metadata.name}')

if [ -z "${APP_NAMESPACES}" ]; then
    echo "No application namespaces found."
    declare -a NAMESPACE_ARRAY=() # Initialize empty array
else
    # Convert space-separated string to array
    read -r -a NAMESPACE_ARRAY <<< "${APP_NAMESPACES}"
    echo "Found application namespaces: ${NAMESPACE_ARRAY[*]}"
fi

# 4. Run oc adm inspect for each application namespace
if [ ${#NAMESPACE_ARRAY[@]} -gt 0 ]; then
    echo "Running 'oc adm inspect' for each application namespace..."
    for NS in "${NAMESPACE_ARRAY[@]}"; do
        echo "  - Inspecting namespace: ${NS}"
        if ! oc adm inspect "ns/${NS}" --dest-dir="${REPORT_DIR}"; then
            echo "    WARNING: 'oc adm inspect' failed for namespace '${NS}'. Continuing."
        fi
    done
    echo "'oc adm inspect' collection complete."
else
    echo "Skipping 'oc adm inspect' as no application namespaces were found."
fi

# 5. Compress all collected oc adm inspect directories
# This will tar up any directories created by oc adm inspect within the REPORT_DIR,
# but it will exclude the sosreport itself if it was generated.
OC_INSPECT_ARCHIVE="${REPORT_DIR}/oc_adm_inspect_reports_${CURRENT_TIMESTAMP}.tar.gz"
echo "Compressing 'oc adm inspect' reports..."
# Find all directories created by oc adm inspect, excluding the main report dir itself
# and also excluding the sosreport file
find "${REPORT_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | xargs -0 tar -czvf "${OC_INSPECT_ARCHIVE}" --exclude='sosreport-microshift-*.tar.xz'
if [ $? -ne 0 ]; then
    echo "WARNING: Failed to compress 'oc adm inspect' reports."
else
    echo "Compressed 'oc adm inspect' reports to: ${OC_INSPECT_ARCHIVE}"
fi


# 6. Clean up temporary directories (if any files were created outside the final archives)
# Note: For this script, the temporary directory IS the final destination,
# so cleanup isn't strictly necessary for the main report dir itself.
# However, if you had intermediate files you wanted to remove, this is where you'd do it.
# For now, we'll just confirm where the reports are.

echo ""
echo "--------------------------------------------------------"
echo "Report collection complete."
echo "All collected reports are located in: ${REPORT_DIR}"
echo "--------------------------------------------------------"

# Optional: Unset KUBECONFIG to avoid affecting subsequent shell commands
unset KUBECONFIG
