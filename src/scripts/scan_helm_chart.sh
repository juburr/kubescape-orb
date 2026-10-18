#!/bin/bash

set -euo pipefail

# Prepare orb parameters
ARTIFACTS_DIR=$(printf '%s' "${PARAM_ARTIFACTS_DIR}" | circleci env subst)
CHART=$(printf '%s' "${PARAM_CHART}" | circleci env subst)
FRAMEWORK="${PARAM_FRAMEWORK}"
OUTPUT_FILE=$(printf '%s' "${PARAM_OUTPUT_FILE}" | circleci env subst)
OUTPUT_FORMAT="${PARAM_OUTPUT_FORMAT}"
RELEASE_NAMESPACE=$(printf '%s' "${PARAM_RELEASE_NAMESPACE}" | circleci env subst)
VERBOSE=$(printf '%s' "${PARAM_VERBOSE}" | circleci env subst)

# The chart is rendered into a private temporary directory, which is removed on
# every exit, including a failed scan: the rendered manifests can hold Secret
# values from the chart.
YAML_DIR=$(mktemp -d)
trap 'rm -rf "${YAML_DIR}"' EXIT

# Print parameters for debugging purposes.
echo "Running Kubescape Helm chart scan..."
echo "  ARTIFACTS_DIR: ${ARTIFACTS_DIR}"
echo "  CHART: ${CHART}"
echo "  FRAMEWORK: ${FRAMEWORK}"
echo "  OUTPUT_FILE: ${OUTPUT_FILE}"
echo "  OUTPUT_FORMAT: ${OUTPUT_FORMAT}"
echo "  RELEASE_NAMESPACE: ${RELEASE_NAMESPACE}"
echo "  YAML_DIR: ${YAML_DIR}"
echo "  VERBOSE: ${VERBOSE}"

VERBOSE_ARG=()
if [[ "${VERBOSE}" == "1" ]]; then
    VERBOSE_ARG=(--verbose)
fi

# Scanning from pre-downloaded artifacts is how this orb runs without network
# access, so always skip Kubescape's update check, even if the job sets
# KS_SKIP_UPDATE_CHECK=false. Otherwise it still contacts
# version-check.ks-services.co, which stalls for about a minute on networks
# that silently drop connections.
ARTIFACTS_ARG=()
if [[ -n "${ARTIFACTS_DIR}" ]]; then
    if [[ ! -d "${ARTIFACTS_DIR}" ]]; then
        echo "ERROR: artifacts_dir '${ARTIFACTS_DIR}' is not a directory. Create it with 'kubescape download artifacts --output <dir>'." >&2
        exit 1
    fi
    ARTIFACTS_ARG=(--use-artifacts-from "${ARTIFACTS_DIR}")
    export KS_SKIP_UPDATE_CHECK=true
fi

# Kubescape takes Kubernetes YAML files as input, but we just have a
# Helm chart at this point. Run the template command to render it into a
# single YAML file. The namespace only sets .Release.Namespace.
helm template "${CHART}" -n "${RELEASE_NAMESPACE}" > "${YAML_DIR}/chart.yaml"

# Scan the YAML file using Kubescape. Stdin is redirected because Kubescape 4.x
# panics while printing verbose results when stdin is a terminal, as it is in
# CircleCI steps; the scan reads the chart from the file, not stdin.
# VERBOSE_ARG and ARTIFACTS_ARG can be empty, and bash before 4.4 treats an
# empty array as unset under set -u, so each is expanded only when it has
# elements.
kubescape scan framework "${FRAMEWORK}" \
    ${VERBOSE_ARG[@]+"${VERBOSE_ARG[@]}"} \
    ${ARTIFACTS_ARG[@]+"${ARTIFACTS_ARG[@]}"} \
    --format "${OUTPUT_FORMAT}" \
    --output "${OUTPUT_FILE}" \
    "${YAML_DIR}/chart.yaml" < /dev/null

# Kubescape appends the format's extension when OUTPUT_FILE doesn't already end
# with it (4.x does so for every format), so point at the real file if needed.
if [[ ! -e "${OUTPUT_FILE}" ]]; then
    echo "WARN: ${OUTPUT_FILE} was not written. Kubescape appends the ${OUTPUT_FORMAT} format's extension when the name lacks it; found:" >&2
    ls -1 "${OUTPUT_FILE}".* >&2 2> /dev/null || echo "WARN: no ${OUTPUT_FILE}.* files either." >&2
fi
