#!/bin/bash
#
# Offline tests for src/scripts/install.sh. Each case runs the install script in
# a scratch directory with wget and curl replaced by stubs that record the
# requested URL and fail, so nothing is ever downloaded. Cases that need a
# binary seed the kubescape.tar.gz cache file the script picks up from its
# working directory.
#
# Usage: tests/install_test.sh (requires the circleci CLI for `circleci env subst`)

set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_SCRIPT="${REPO_ROOT}/src/scripts/install.sh"
LISTED_VERSION="4.0.15"
UNLISTED_VERSION="0.0.1"

# Read the command's default from the orb source, so "by default" below always
# means what users get when they don't set verify_checksums.
DEFAULT_VERIFY_CHECKSUMS=$(awk '
    /^  verify_checksums:/ { in_param = 1; next }
    in_param && /^  [a-z_]+:/ { exit }
    in_param && /^    default:/ { print $2; exit }
' "${REPO_ROOT}/src/commands/install.yml")

if [[ -z "${DEFAULT_VERIFY_CHECKSUMS}" ]]; then
    echo "FAIL: could not read the verify_checksums default from src/commands/install.yml"
    exit 1
fi
if ! command -v circleci > /dev/null; then
    echo "FAIL: the circleci CLI is required (install.sh uses 'circleci env subst')"
    exit 1
fi
echo "verify_checksums default: ${DEFAULT_VERIFY_CHECKSUMS}"

WORK_ROOT=$(mktemp -d)
trap 'rm -rf "${WORK_ROOT}"' EXIT

STUB_BIN="${WORK_ROOT}/stub-bin"
mkdir -p "${STUB_BIN}"
for tool in wget curl; do
    cat > "${STUB_BIN}/${tool}" << 'EOF'
#!/bin/bash
echo "$*" >> "${DOWNLOAD_LOG}"
exit 1
EOF
    chmod +x "${STUB_BIN}/${tool}"
done

FAILURES=0
CASE_DIR=""
OUTPUT=""
STATUS=0

# run_install NAME VERSION VERIFY_CHECKSUMS [CACHED_BINARY]
#   VERIFY_CHECKSUMS of "<unset>" leaves PARAM_VERIFY_CHECKSUMS out of the environment.
#   CACHED_BINARY, when given, becomes the contents of the cached kubescape binary.
run_install() {
    local name="$1" version="$2" verify="$3" cached_binary="${4-}"
    CASE_DIR="${WORK_ROOT}/${name// /_}"
    mkdir -p "${CASE_DIR}/work"
    if [[ -n "${cached_binary}" ]]; then
        printf '%s' "${cached_binary}" > "${CASE_DIR}/work/kubescape"
        tar czf "${CASE_DIR}/work/kubescape.tar.gz" -C "${CASE_DIR}/work" kubescape
        rm "${CASE_DIR}/work/kubescape"
    fi
    local env_args=(
        "PATH=${STUB_BIN}:${PATH}"
        "DOWNLOAD_LOG=${CASE_DIR}/downloads.log"
        "PARAM_INSTALL_PATH=${CASE_DIR}/bin"
        "PARAM_VERSION=${version}"
    )
    if [[ "${verify}" != "<unset>" ]]; then
        env_args+=("PARAM_VERIFY_CHECKSUMS=${verify}")
    fi
    OUTPUT=$(cd "${CASE_DIR}/work" && env -u PARAM_VERIFY_CHECKSUMS "${env_args[@]}" bash "${INSTALL_SCRIPT}" 2>&1)
    STATUS=$?
}

pass() {
    echo "ok   - $1"
}

fail() {
    echo "FAIL - $1"
    local line
    while IFS= read -r line; do
        echo "       | ${line}"
    done <<< "${OUTPUT}"
    FAILURES=$((FAILURES + 1))
}

# expect_failure NAME PATTERN: non-zero exit, output matches PATTERN, nothing installed.
expect_failure() {
    local name="$1" pattern="$2"
    if [[ "${STATUS}" -eq 0 ]]; then
        fail "${name}: expected a non-zero exit status"
    elif ! grep -qE "${pattern}" <<< "${OUTPUT}"; then
        fail "${name}: output does not match /${pattern}/"
    elif [[ -e "${CASE_DIR}/bin/kubescape" ]]; then
        fail "${name}: kubescape was installed"
    else
        pass "${name}"
    fi
}

# expect_success NAME [PATTERN]: zero exit, kubescape installed, output matches PATTERN if given.
expect_success() {
    local name="$1" pattern="${2-}"
    if [[ "${STATUS}" -ne 0 ]]; then
        fail "${name}: expected exit status 0, got ${STATUS}"
    elif [[ ! -x "${CASE_DIR}/bin/kubescape" ]]; then
        fail "${name}: kubescape was not installed"
    elif [[ -n "${pattern}" ]] && ! grep -qE "${pattern}" <<< "${OUTPUT}"; then
        fail "${name}: output does not match /${pattern}/"
    else
        pass "${name}"
    fi
}

# expect_no_download NAME: the case never tried to fetch a binary.
expect_no_download() {
    local name="$1"
    if [[ -s "${CASE_DIR}/downloads.log" ]]; then
        fail "${name}: attempted a download: $(cat "${CASE_DIR}/downloads.log")"
    else
        pass "${name}"
    fi
}

NO_CHECKSUM="No SHA-512 checksum available for Kubescape ${UNLISTED_VERSION}"
MISMATCH="Checksum verification failed"

run_install "unlisted default" "${UNLISTED_VERSION}" "${DEFAULT_VERIFY_CHECKSUMS}"
expect_failure "unlisted version fails by default" "${NO_CHECKSUM}"
expect_no_download "unlisted version fails by default before downloading"

run_install "unlisted unset" "${UNLISTED_VERSION}" "<unset>"
expect_failure "unlisted version fails when verify_checksums is unset" "${NO_CHECKSUM}"

run_install "unlisted strict" "${UNLISTED_VERSION}" "strict"
expect_failure "unlisted version fails in strict mode" "${NO_CHECKSUM}"

run_install "unlisted known_versions" "${UNLISTED_VERSION}" "known_versions" "unlisted binary"
expect_success "unlisted version installs unverified with known_versions" "WARN: No SHA-512 checksum"

run_install "unlisted false" "${UNLISTED_VERSION}" "false" "unlisted binary"
expect_success "unlisted version installs with verification disabled" "Checksum validation is disabled"

run_install "tampered default" "${LISTED_VERSION}" "${DEFAULT_VERIFY_CHECKSUMS}" "tampered binary"
expect_failure "tampered binary for a listed version fails by default" "${MISMATCH}"

run_install "tampered known_versions" "${LISTED_VERSION}" "known_versions" "tampered binary"
expect_failure "tampered binary for a listed version fails with known_versions" "${MISMATCH}"

run_install "tampered false" "${LISTED_VERSION}" "false" "tampered binary"
expect_success "tampered binary installs only when verification is disabled"

run_install "invalid mode" "${LISTED_VERSION}" "bogus"
expect_failure "invalid verify_checksums value fails" "Invalid verify_checksums value 'bogus'"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} test(s) failed."
    exit 1
fi
echo "All install.sh tests passed."
