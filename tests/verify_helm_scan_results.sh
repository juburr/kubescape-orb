#!/bin/bash
#
# Checks the reports written by the helm-scan-test job in test-deploy.yml.
#
# Usage: tests/verify_helm_scan_results.sh RESULTS_DIR KUBESCAPE_VERSION

set -uo pipefail

RESULTS_DIR="$1"
KUBESCAPE_VERSION="${2#v}"
KUBESCAPE_MAJOR="${KUBESCAPE_VERSION%%.*}"
FAILURES=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "ok   - ${name}"
    else
        echo "FAIL - ${name}"
        FAILURES=$((FAILURES + 1))
    fi
}

# JSON reports name the scanned framework in their summary.
for spec in nsa:NSA mitre:MITRE soc2:SOC2 cis-v1.12.0:cis-v1.12.0; do
    file="${RESULTS_DIR}/${spec%%:*}.json"
    framework="${spec#*:}"
    # shellcheck disable=SC2016 # $fw is a jq variable
    check "${file##*/} reports framework ${framework}" \
        jq -e --arg fw "${framework}" '.summaryDetails.frameworks | map(.name) | index($fw)' "${file}"
done
# shellcheck disable=SC2016 # $names is a jq variable
check "all.json covers NSA, MITRE, SOC2 and cis-v1.12.0" \
    jq -e '.summaryDetails.frameworks | map(.name) as $names | ["NSA", "MITRE", "SOC2", "cis-v1.12.0"] - $names == []' \
    "${RESULTS_DIR}/all.json"

# These scans found failed controls yet their steps passed, so findings alone
# don't fail the job. (The sample chart passes every MITRE control.)
for name in nsa soc2 cis-v1.12.0 all; do
    check "${name}.json has failed controls" \
        jq -e '[.summaryDetails.controls[] | select(.status == "failed")] | length > 0' "${RESULTS_DIR}/${name}.json"
done

# Formats supported by every Kubescape version this orb installs.
check "nsa.sarif is SARIF 2.1.0" jq -e '.version == "2.1.0"' "${RESULTS_DIR}/nsa.sarif"
check "nsa.xml is a JUnit report" grep -q '<testsuites' "${RESULTS_DIR}/nsa.xml"
check "nsa.html is an HTML report" grep -qi '<html' "${RESULTS_DIR}/nsa.html"
check "nsa.pdf is a PDF" grep -q '^%PDF' "${RESULTS_DIR}/nsa.pdf"
check "nsa.prom.txt has Prometheus metrics" grep -q 'kubescape_cluster_complianceScore' "${RESULTS_DIR}/nsa.prom.txt"
check "nsa.txt is a non-empty pretty-printer report" test -s "${RESULTS_DIR}/nsa.txt"

# Formats added in Kubescape 4. (3.x silently writes pretty-printer output for
# these, and its SARIF output has no results for rendered charts.)
if [[ "${KUBESCAPE_MAJOR}" -ge 4 ]]; then
    check "nsa.sarif has results" jq -e '[.runs[].results[]] | length > 0' "${RESULTS_DIR}/nsa.sarif"
    check "nsa.csv is CSV" grep -q '^Control Name,Control ID' "${RESULTS_DIR}/nsa.csv"
    check "nsa.md is Markdown" grep -q '^# Kubescape' "${RESULTS_DIR}/nsa.md"
    check "nsa.yaml is a YAML report" grep -q '^summaryDetails:' "${RESULTS_DIR}/nsa.yaml"
    check "nsa.gitlab-sast.json has vulnerabilities" jq -e '.vulnerabilities | length > 0' "${RESULTS_DIR}/nsa.gitlab-sast.json"
    check "nsa.github-actions.txt has workflow commands" grep -q '^::' "${RESULTS_DIR}/nsa.github-actions.txt"
    check "nsa.policyreport.yaml is a PolicyReport" grep -q '^kind: .*PolicyReport' "${RESULTS_DIR}/nsa.policyreport.yaml"
    check "nsa.exceptions.json is a list of exceptions" jq -e 'type == "array" and length > 0' "${RESULTS_DIR}/nsa.exceptions.json"
fi

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All scan result checks passed for Kubescape ${KUBESCAPE_VERSION}."
