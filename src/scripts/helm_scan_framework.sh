#!/bin/bash

set -e
set +o history

# Prepare orb parameters
ARTIFACTS_PATH=$(circleci env subst "${PARAM_ARTIFACTS_PATH}")
CHART_PATH=$(circleci env subst "${PARAM_CHART_PATH}")
FRAMEWORK="${PARAM_FRAMEWORK}"
NAMESPACE=$(circleci env subst "${PARAM_NAMESPACE}")
OUTPUT_FILE=$(circleci env subst "${PARAM_OUTPUT_FILE}")
OUTPUT_FORMAT="${PARAM_OUTPUT_FORMAT}"
YAML_DIR="${HOME}/.local/share/kubescape-orb/yamls"
VERBOSE=$(circleci env subst "${PARAM_VERBOSE}")

# Print parameters for debugging purposes.
echo "Running Kubescape framework scan..."
echo "  ARTIFACTS_PATH: ${ARTIFACTS_PATH}"
echo "  CHART_PATH: ${CHART_PATH}"
echo "  FRAMEWORK: ${FRAMEWORK}"
echo "  NAMESPACE: ${NAMESPACE}"
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo "  OUTPUT_FORMAT: ${OUTPUT_FORMAT}"
echo "  YAML_DIR: ${YAML_DIR}"
echo "  VERBOSE: ${VERBOSE}"

VERBOSE_ARG=()
if [[ "${VERBOSE}" == "1" ]]; then
    VERBOSE_ARG=(--verbose)
fi

# Scanning from pre-downloaded artifacts is how this orb runs without network
# access, so also skip Kubescape's update check. Otherwise it still contacts
# version-check.ks-services.co, which stalls for about a minute on networks
# that silently drop connections.
ARTIFACTS_ARG=()
if [[ -n "${ARTIFACTS_PATH}" ]]; then
    if [[ ! -d "${ARTIFACTS_PATH}" ]]; then
        echo "ERROR: artifacts_path '${ARTIFACTS_PATH}' is not a directory. Create it with 'kubescape download artifacts --output <dir>'."
        exit 1
    fi
    ARTIFACTS_ARG=(--use-artifacts-from "${ARTIFACTS_PATH}")
    export KS_SKIP_UPDATE_CHECK="${KS_SKIP_UPDATE_CHECK:-true}"
fi

# Kubescape takes Kubernetes YAML files as input, but we just have a
# Helm chart (.tar.gz file) at this point. Run the template command to
# transform it into a single YAML file.
mkdir -p "${YAML_DIR}"
helm template "${CHART_PATH}" -n "${NAMESPACE}" > "${YAML_DIR}/chart.yaml"

# Scan the YAML file using Kubescape. Stdin is redirected because Kubescape 4.x
# panics while printing verbose results when stdin is a terminal, as it is in
# CircleCI steps; the scan reads the chart from the file, not stdin.
kubescape scan framework "${FRAMEWORK}" \
    "${VERBOSE_ARG[@]}" \
    "${ARTIFACTS_ARG[@]}" \
    --format "${OUTPUT_FORMAT}" \
    --output "${OUTPUT_FILE}" \
    "${YAML_DIR}/chart.yaml" < /dev/null

# Kubescape appends the format's extension when OUTPUT_FILE doesn't already end
# with it (4.x does so for every format), so point at the real file if needed.
if [[ ! -e "${OUTPUT_FILE}" ]]; then
    echo "WARN: ${OUTPUT_FILE} was not written. Kubescape appends the ${OUTPUT_FORMAT} format's extension when the name lacks it; found:"
    ls -1 "${OUTPUT_FILE}".* 2> /dev/null || echo "WARN: no ${OUTPUT_FILE}.* files either."
fi

# Cleanup temporary files
rm "${YAML_DIR}/chart.yaml"
