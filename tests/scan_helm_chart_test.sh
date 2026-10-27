#!/usr/bin/env bash
#
# Tests src/scripts/scan_helm_chart.sh with stand-ins for helm and kubescape
# that record their arguments:
#
#   - the chart is rendered into a private temporary directory that is removed
#     on every exit, including a failed scan, and nothing is left in HOME
#   - errors and warnings go to stderr with ERROR: and WARN: prefixes
#   - without verbose and artifacts_dir, kubescape gets no extra arguments,
#     even on bash < 4.4
#   - without the CircleCI CLI, as in GitHub Actions, values are used as they
#     are; verbose takes true and false as well as 1 and 0; and a framework,
#     output_format or verbose the command's YAML wouldn't allow fails before
#     helm runs
#
# The helm-scan-test jobs in test-deploy.yml run the same script with the real
# helm and kubescape.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPT="${ROOT}/src/scripts/scan_helm_chart.sh"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/cli" "${WORK}/home" "${WORK}/tmp" "${WORK}/results" "${WORK}/artifacts"

# The scripts pass values on stdin, as with the real `circleci env subst`. It
# is in a directory of its own, which run_scan leaves off the PATH with
# PATH="${NO_CLI_PATH}".
printf '#!/bin/sh\ncat\n' > "${WORK}/cli/circleci"
NO_CLI_PATH="${WORK}/bin:/usr/bin:/bin"

# helm template prints a manifest with a Secret, as a chart's values can.
cat > "${WORK}/bin/helm" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${WORK}/helm-args"
printf 'apiVersion: v1\nkind: Secret\ndata:\n  password: c2VjcmV0LXZhbHVl\n'
EOF

# kubescape records its arguments and where the rendered chart was, then
# writes the report: to --output, to --output plus .json with
# KS_APPEND_EXTENSION=1, or nowhere with KS_WRITE=0. KS_EXIT sets its status.
cat > "${WORK}/bin/kubescape" << 'EOF'
#!/bin/bash
printf '%s\n' "$@" > "${WORK}/kubescape-args"
printf '%s\n' "${KS_SKIP_UPDATE_CHECK:-<unset>}" > "${WORK}/kubescape-skip-update"
output=""
while [[ $# -gt 1 ]]; do
    if [[ "$1" == "--output" ]]; then
        output="$2"
    fi
    shift
done
chart="$1"
printf '%s\n' "${chart}" > "${WORK}/kubescape-chart-path"
cp "${chart}" "${WORK}/kubescape-chart-copy" 2> /dev/null
if [[ "${KS_WRITE:-1}" == "1" ]]; then
    if [[ "${KS_APPEND_EXTENSION:-0}" == "1" ]]; then
        output="${output}.json"
    fi
    printf '{}\n' > "${output}"
fi
exit "${KS_EXIT:-0}"
EOF
chmod +x "${WORK}/cli/circleci" "${WORK}/bin/helm" "${WORK}/bin/kubescape"

FAILURES=0
RC=0
STDOUT=""
STDERR=""

# run_scan [VAR=value ...]: runs scan_helm_chart.sh in an environment with
# only the given variables, the parameters and the stand-ins, and sets RC,
# STDOUT and STDERR. A later VAR=value replaces an earlier one.
run_scan() {
    rm -f "${WORK}"/helm-args "${WORK}"/kubescape-* "${WORK}"/results/*
    env -i \
        PATH="${WORK}/cli:${WORK}/bin:/usr/bin:/bin" \
        HOME="${WORK}/home" \
        TMPDIR="${WORK}/tmp" \
        WORK="${WORK}" \
        PARAM_ARTIFACTS_DIR="" \
        PARAM_CHART="${WORK}/myservice-0.1.0.tgz" \
        PARAM_FRAMEWORK="nsa" \
        PARAM_OUTPUT_FILE="${WORK}/results/nsa.json" \
        PARAM_OUTPUT_FORMAT="json" \
        PARAM_RELEASE_NAMESPACE="kubescape-orb" \
        PARAM_VERBOSE="1" \
        "$@" \
        bash "${SCRIPT}" > "${WORK}/stdout" 2> "${WORK}/stderr"
    RC=$?
    STDOUT=$(cat "${WORK}/stdout")
    STDERR=$(cat "${WORK}/stderr")
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | stdout: %s\n' "${STDOUT}"
        printf '    | stderr: %s\n' "${STDERR}"
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
stderr_has() { grep -qxF -- "$1" <<< "${STDERR}"; }
stderr_is_empty() { [[ -z "${STDERR}" ]]; }
stdout_lacks() { ! grep -qF -- "$1" <<< "${STDOUT}"; }
args_have() { grep -qxF -- "$1" "${WORK}/$2"; }
# kubescape_args_are ARG...: kubescape got exactly these arguments, then the
# rendered chart's path.
kubescape_args_are() {
    [[ -f "${WORK}/kubescape-args" && -f "${WORK}/kubescape-chart-path" ]] &&
        [[ "$(cat "${WORK}/kubescape-args")" == "$(printf '%s\n' "$@" "$(cat "${WORK}/kubescape-chart-path")")" ]]
}
tmp_is_empty() { [[ -z "$(ls -A "${WORK}/tmp")" ]]; }
home_is_empty() { [[ -z "$(find "${WORK}/home" -mindepth 1 -print -quit)" ]]; }
# The rendered chart was in a private directory under TMPDIR, held the
# manifest, and no longer exists.
chart_was_private() {
    local path dir
    path=$(cat "${WORK}/kubescape-chart-path" 2> /dev/null) || return 1
    dir=$(dirname "${path}")
    [[ "${dir}" == "${WORK}/tmp/"* ]] &&
        grep -qF "kind: Secret" "${WORK}/kubescape-chart-copy" &&
        [[ ! -e "${path}" && ! -e "${dir}" ]]
}

run_scan
check "scans the chart" rc_is_zero
check "renders the chart with the release namespace" args_have "kubescape-orb" helm-args
check "passes the framework" args_have "nsa" kubescape-args
check "passes --verbose" args_have "--verbose" kubescape-args
check "writes the report" test -s "${WORK}/results/nsa.json"
check "renders the chart into a private directory that is removed" chart_was_private
check "leaves nothing in TMPDIR" tmp_is_empty
check "leaves nothing in HOME" home_is_empty
check "prints nothing on stderr" stderr_is_empty

# Without verbose and artifacts_dir, VERBOSE_ARG and ARTIFACTS_ARG are empty.
# Bash before 4.4 treats an empty array as unset under set -u, so unguarded
# expansions of them stop the script before kubescape runs. The exact
# arguments also rule out an empty one in their place.
run_scan PARAM_VERBOSE="0"
check "scans without verbose and artifacts_dir" rc_is_zero
check "passes no extra arguments to kubescape" \
    kubescape_args_are scan framework nsa --format json --output "${WORK}/results/nsa.json"

run_scan KS_EXIT=1
check "fails when kubescape fails" rc_is_nonzero
check "removes the rendered chart after a failed scan" chart_was_private
check "leaves nothing in TMPDIR after a failed scan" tmp_is_empty
check "leaves nothing in HOME after a failed scan" home_is_empty

run_scan PARAM_ARTIFACTS_DIR="${WORK}/artifacts"
check "scans with artifacts" rc_is_zero
check "passes --use-artifacts-from" args_have "--use-artifacts-from" kubescape-args
check "skips the update check with artifacts" args_have "true" kubescape-skip-update

run_scan PARAM_ARTIFACTS_DIR="${WORK}/no-such-dir"
check "refuses a missing artifacts_dir" rc_is_nonzero
check "explains the missing artifacts_dir on stderr" \
    stderr_has "ERROR: artifacts_dir '${WORK}/no-such-dir' is not a directory. Create it with 'kubescape download artifacts --output <dir>'."
check "prints no error on stdout" stdout_lacks "ERROR:"
check "leaves nothing in TMPDIR after refusing" tmp_is_empty

run_scan PARAM_OUTPUT_FILE="${WORK}/results/nsa" KS_APPEND_EXTENSION=1
check "succeeds when kubescape appends an extension" rc_is_zero
check "warns on stderr that the named file was not written" \
    stderr_has "WARN: ${WORK}/results/nsa was not written. Kubescape appends the json format's extension when the name lacks it; found:"
check "lists the file kubescape wrote on stderr" stderr_has "${WORK}/results/nsa.json"
check "prints no warning on stdout" stdout_lacks "WARN:"

run_scan KS_WRITE=0
check "succeeds when kubescape writes no file" rc_is_zero
check "warns on stderr that no file was found" stderr_has "WARN: no ${WORK}/results/nsa.json.* files either."

# GitHub Actions: no CircleCI CLI, and booleans as true and false.
# shellcheck disable=SC2016 # a literal $NAME, which only the CLI would expand
run_scan PATH="${NO_CLI_PATH}" PARAM_VERBOSE="true" PARAM_RELEASE_NAMESPACE='-n$NAME'
check "scans without the CircleCI CLI" rc_is_zero
check "passes --verbose for verbose true" args_have "--verbose" kubescape-args
# shellcheck disable=SC2016 # the literal value helm must get
check "uses a value as it is without the CLI, even one starting with - or holding \$NAME" args_have '-n$NAME' helm-args
run_scan PATH="${NO_CLI_PATH}" PARAM_VERBOSE="false"
check "scans with verbose false" rc_is_zero
check "passes no --verbose for verbose false" \
    kubescape_args_are scan framework nsa --format json --output "${WORK}/results/nsa.json"

# CircleCI checks these before the step runs; an action input can be anything.
run_scan PARAM_VERBOSE="yes"
check "refuses a verbose that isn't true or false" rc_is_nonzero
check "saying so on stderr" stderr_has "ERROR: verbose must be true or false, not 'yes'."
check "before rendering the chart" test ! -e "${WORK}/helm-args"
run_scan PARAM_FRAMEWORK="nsa2"
check "refuses an unknown framework" rc_is_nonzero
check "saying so on stderr" \
    stderr_has "ERROR: framework 'nsa2' is not one of the frameworks the orb supports (see the scan_helm_chart command's framework parameter)."
check "before rendering the chart" test ! -e "${WORK}/helm-args"
run_scan PARAM_OUTPUT_FORMAT="spdx-json"
check "refuses an unknown output_format" rc_is_nonzero
check "saying so on stderr" \
    stderr_has "ERROR: output_format 'spdx-json' is not one of the formats the orb supports (see the scan_helm_chart command's output_format parameter)."
check "before rendering the chart" test ! -e "${WORK}/helm-args"

# Every framework and format the command's YAML allows passes the script's checks.
yaml_enum() {
    awk -v name="  $1:" '
        $0 == name { inside = 1; next }
        inside && /^  [a-z_]+:/ { exit }
        inside && /^      - "/ { value = $0; sub(/^      - "/, "", value); sub(/"$/, "", value); print value }
    ' "${ROOT}/src/commands/scan_helm_chart.yml"
}
refused=""
while IFS= read -r framework; do
    run_scan PARAM_FRAMEWORK="${framework}"
    [[ "${RC}" -eq 0 ]] || refused+="framework ${framework}; "
done < <(yaml_enum framework)
while IFS= read -r format; do
    run_scan PARAM_OUTPUT_FORMAT="${format}"
    [[ "${RC}" -eq 0 ]] || refused+="output_format ${format}; "
done < <(yaml_enum output_format)
STDOUT="" STDERR="${refused}"
check "accepts every framework and output_format the command allows" test -z "${refused}"
check "and the command allows some of each" test "$(yaml_enum framework | wc -l)" -gt 10 -a "$(yaml_enum output_format | wc -l)" -gt 10

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All scan_helm_chart tests passed."
