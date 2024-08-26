#!/bin/bash

set -e
set +o history

# Prepare orb parameters
CHART_PATH=$(circleci env subst "${PARAM_CHART_PATH}")
FRAMEWORK="${PARAM_FRAMEWORK}"
NAMESPACE=$(circleci env subst "${PARAM_NAMESPACE}")
OUTPUT_FILE=$(circleci env subst "${PARAM_OUTPUT_FILE}")
OUTPUT_FORMAT="${PARAM_OUTPUT_FORMAT}"
YAML_DIR="${HOME}/.local/share/kubescape-orb/yamls"
VERBOSE=$(circleci env subst "${PARAM_VERBOSE}")

# Print parameters for debugging purposes.
echo "Running Kubescape framework scan..."
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

# Kubescape takes Kubernetes YAML files as input, but we just have a
# Helm chart (.tar.gz file) at this point. Run the template command to
# transform it into a signle YAML file.
mkdir -p "${YAML_DIR}"
helm template "${CHART_PATH}" -n "${NAMESPACE}" > "${YAML_DIR}/chart.yaml"

# Scan the YAML file using Kubescape
kubescape scan framework "${FRAMEWORK}" \
    "${VERBOSE_ARG[@]}" \
    --format "${OUTPUT_FORMAT}" \
    --output "${OUTPUT_FILE}" \
    "${YAML_DIR}/chart.yaml"

# Cleanup temporary files
rm "${YAML_DIR}/chart.yaml"
