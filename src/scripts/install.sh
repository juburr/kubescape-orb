#!/bin/bash
#
# Installs Kubescape for the install command: the Linux amd64 or arm64 build
# that matches this machine, verified against the checksum table in this file
# before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (Kubescape only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing Kubescape needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="kubescape-orb"
TOOL_NAME="Kubescape"
TOOL_BINARY="kubescape"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# tool_asset_name VERSION ARCH: the release asset to download.
tool_asset_name() {
    # GoReleaser renamed the Linux binaries in 3.0.47.
    if printf '%s\n%s\n' 3.0.47 "$1" | sort -C -V; then
        printf 'kubescape_%s_linux_%s\n' "$1" "$2"
    elif [[ "$2" == "arm64" ]]; then
        printf 'kubescape-arm64-ubuntu-latest\n'
    else
        printf 'kubescape-ubuntu-latest\n'
    fi
}

# tool_asset_urls VERSION ARCH ASSET: where to download it, one URL per line,
# tried in order.
tool_asset_urls() {
    printf 'https://github.com/kubescape/kubescape/releases/download/v%s/%s\n' "$1" "$3"
}

# tool_archive_member VERSION ARCH: empty, since Kubescape publishes bare
# binaries. The checksum table holds the SHA-512 of the asset itself.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    KS_SKIP_UPDATE_CHECK=true "$1" version
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools sha512sum mktemp
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty.
orb_extract() {
    local asset=$1 member=$2 dir
    if [[ -z "${member}" ]]; then
        ORB_VERIFIED_FILE=${asset}
        return 0
    fi
    dir="${ORB_WORK_DIR}/extract"
    rm -rf "${dir}"
    mkdir "${dir}"
    if ! tar -xzf "${asset}" -C "${dir}" --no-same-owner -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
        orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
        return 1
    fi
    ORB_VERIFIED_FILE="${dir}/${member}"
    if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            cp "${ORB_CACHE_FILE}" "${asset}"
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            rm -f "${ORB_CACHE_FILE}"
            use_cache=false
            continue
        fi
        orb_die "${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) failed verification and was not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST,
# replacing any existing file in a single rename.
orb_install_file() {
    local dir=${2%/*}
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if ! { orb_temp_beside "$2" && cp "$1" "${ORB_TEMP}" && chmod 0755 "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "$2"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# Runs the installed binary once, which catches a build that can't run here.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "${ORB_INSTALL_PATH}/${TOOL_BINARY}" 2>&1) || rc=$?
    if [[ "${rc}" -eq 126 || "${rc}" -eq 127 ]]; then
        orb_die "The installed ${TOOL_BINARY} cannot run on this machine (exit code ${rc}): ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
    if [[ "${rc}" -ne 0 ]]; then
        orb_warn "Asking ${TOOL_BINARY} for its version exited with code ${rc}."
    fi
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_smoke_test
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["4.0.15/amd64"]="eba2d3600d40fcafc54ad4bed6b8a4890dd8403b3093a3171c80c973969405a340f97a8c6bcbf0a3b574051fcf7d6d5c967eddb47b558e4f2d32050ff9a362f5"
    ["4.0.15/arm64"]="b188f3d08d7b3f69ce3f72b7fc8491f503c23f86276a9c232b06414b62aa5d5424da590c3465b8580304bd6e36dda26c199e16e8fcedd7a4cf22544fb4088cf6"
    ["4.0.14/amd64"]="27cc519225dc0d53e2434e6c2c09ad8e94dbb05844a70f80316c5bbe9a13c9dfab25576c827b741745facfbb00202995e644d46adbf5556a5ca742347cbb6b6e"
    ["4.0.14/arm64"]="fd32d338237c14d0900e3ff4e565a7d0bead14b599afe219f58751b6bebecbf460c4f9909a9d1315733e169ae3873c1110ef3896846abc72808bf8cc12924d5b"
    ["4.0.13/amd64"]="2260cf77dbc9c3664809823f1db6ca04eb87f173dd1a93e233277aa3a759d7e57e728d47c7f9e7e4306b2e8e3609add5fcd07a2495770ed403b9262d8f25b6eb"
    ["4.0.13/arm64"]="6903736147ac540a0bcc3bac791b3d2328c0d9c178445649958b629ca4301299adc1a978ce595d4dfce126a6e95063f41f5d8ffc78a4c811920a596db2e7a60f"
    ["4.0.12/amd64"]="d9a268370e7542d0b55c7ab37837811e956a4e53ee021a0c07f4d939a5314b5cef5ae6d03659e5d343834983b22fb91adddc7110763b23f29fe80d8250f00b82"
    ["4.0.12/arm64"]="3de607d89aeece0d4c754f0ca9175adf0cf1cd7bfb886eb2bbc18272e70f38fb2fbd67be695f81a9639fe9f7987f15d7bae4b3ad9efb85f8cc56ed920d72cfeb"
    ["4.0.11/amd64"]="c06efbda7b376fa4df9545e738e56bed750068a98cadf9713acb0c5cd7a05cf10892fe36c02e38ca47e63c866149373be33c1a3d479b7e95049870245baba52b"
    ["4.0.11/arm64"]="84d76c6a9cb6ccd9a0daeaac7d886446f774f7bef05c1d1134362a91f2cef0d358c7a1d6d09c1e216a34035ae66328fd3bf05486ad24e56438041b92e7aef09d"
    ["4.0.10/amd64"]="223689b359b50ee5c5b55bacfda46374902e1af626f585777b9f99273105b85756eb8bbc15439e5d6af9aa98287e13a8414fe450b6acd00962c5eb0966106df4"
    ["4.0.10/arm64"]="e4f87792d1ed7a4f8510886e615ab8b178f7b9978a75276924542a0ef31d3826d3eedd139cedb869c1d1d81413055f32eb2dacef747ff6159f7068d1685f1303"
    ["4.0.9/amd64"]="879e1fb69114c26ab0c1f6f1445e1eb53fc0f18ac990f509d597f352eb08357ea0d646cc9e793de4986afab296317ebc8fcf33bf968cd09be10534b637b16886"
    ["4.0.9/arm64"]="dcb029fe3ac0c6502673477d363fb8234b8f8a114f89c71014b8f6a609d169b877b62791360c5d0772e5a29045f31cf23095ad04e69e25cd56deefb28f143a13"
    ["4.0.8/amd64"]="92e679be5b08d2241521eb5727c69becbad13b788ecd71f7bbaabd6079d0222f9526bc1e9cf16b2cf24709b0844b69eb357b3a92d8880e98605e79685e70bdd7"
    ["4.0.8/arm64"]="4ef577c80560be570a3d8ca503ce8896e0ba0560504e596de41912cb50432aa10ed23baf8d3a804ae7081fe35d8bb145de94e0747fff5c06668c7c63abe06ae4"
    ["4.0.7/amd64"]="bc7738b7622c7cc96fbae8621f56ebdbcc34b0583f149758746c669ccc6b9378399145400811c4671711ce2e7032d65990ba15b920c425b80580585a74d8afb3"
    ["4.0.7/arm64"]="4fe6239f0ca7cea53a6a0d8e74ba58b065128cafe8a78c1f01b5029f519456dbc72ba41c620924dbd552cbd073c56b5a558cfcbc2042a6148d31a50008859a1e"
    ["4.0.6/amd64"]="631ed70246d3b37473c46bca214ce0b4aa5c7c9bc42a83fc4ef884edac5232b7236a52692d81233d24567ac58aa9f9a141a65bc4f5727aec11e2a2a55248991f"
    ["4.0.6/arm64"]="fd9d64fae5778a32d3e5553901420a365566352e02425657b1a204b8c58de44f423b40bc17a7b0de1f09d2e8400784913c597339fbb74cc637784a09f2ea1229"
    ["4.0.5/amd64"]="cc831d56800fa422cc499bed55e54b8057652e1d3564b3bdf66411f5cccc4bdae137c45e178bcbcf098b42d73f0f36849e3321b64f3e48990fa197e0a9dca7ee"
    ["4.0.5/arm64"]="0ece0f94a05a36b2cb2e3840e564bb60df3ef0d8ee7af34f0bc75c318e9f36dff9bd181f1982f5d042fc95aad63899446eae9e16e370efcec519f4d50308f11f"
    ["4.0.4/amd64"]="7c38074d82453bc12494f52f3ac4841e2d8b1925455c52c22512e54a8f1f687b0de15163632e4210d53d8e6b7610fe6cf44317071c67d7be0c14b02e5aee155d"
    ["4.0.4/arm64"]="55605c484a9a308525b9330d6b05683c984e9fc4e53419fbe144688483caabc6c2b0a861215470b7e02f5ef08d3c87bf103974fae27637e3501f2bfa2b5d8262"
    ["4.0.3/amd64"]="ca6a1fd10a9c89f606f9eeb4016912a92a2b847e81441184cf858bf6ad7a2b141368fd2a8a1bff11f18e91a1c57f9a94d586449c9ef0ff4fab9fa6937a2a992b"
    ["4.0.3/arm64"]="cff1223018f63b461603584f06beebebd495350d03dd879c8e89930e26247fe05596becf9ac8336fc84ddfc4d5852e16ea38f646b57b26782515272081665dcf"
    ["4.0.2/amd64"]="5b2f603212be8a7a9af68a26e942760e16018e72e9685c38dfaf66ddeec9f9d47583f6a6605500cf7fafe0116c26a230ec8f42e63a2b735e5808ebc0794e9e4a"
    ["4.0.2/arm64"]="b463a568efda5ea7f13e3cbf60280a43f29e5ff806ac21957ae6cc22d581206ad1686128e8dea613e37a114e693045384f4c97f489e4e6a3e316d866ce6144ee"
    ["4.0.1/amd64"]="45d2aa72796e14b6d4c09842a2df7446016083e586834d9a1f1bd9bc44131f8c10eb0a1e0b28752c07b532632bd82637725f3ef5fdf756756fc9e45d11b4be80"
    ["4.0.1/arm64"]="4b25cc8a04647d4d31097e10aabc6244693ef647974a03c6cebe2e1b5227cf7ffaa71e8be4802ec0634a3ca68e793ac824716c904abd5df1b1c9cdf8e5ea7f17"
    ["4.0.0/amd64"]="c73db44cb545849eb26b719887e9888ac9f78070edaba3596bd4e0fbe749e6193da35e250b43775ff1b32e62519cecac4b52490f4047a92463cea1665a8e88a0"
    ["4.0.0/arm64"]="f6470ab85ac9bf9905a5beefcea3a1227dcaabb657293a6214be8cbc6be392b7ff9a9c51c0e8ac7fa15b74f8b073e182287d5727da879526d380ebdcb4f0e330"
    ["3.0.48/amd64"]="c0650cb4abca6d61c45e6a74118365adb99e53bc59d7322ca6aff54e97cf77eeff938d89278db2812496ab44ff3fdc608a9ae3038c1d31b6a2f29cb11b1e069f"
    ["3.0.48/arm64"]="723b081a79d81dafdc2f530702af12baaf8cf7578e20442c5546a502ea719c78b2144c82787e23c861c14e16a7bae9718c2883d2967dc8b88ad738cb75742f55"
    ["3.0.47/amd64"]="1536d871e99ac06f94d8eba91eae54d49ab7a050e66353a805d300b39074257bafb4192868220c50aad7b61298b2c14d6850c110a1c935703b93f4f64118d667"
    ["3.0.47/arm64"]="3be84582e82ffd0e32c7a59e3f43f5f896f0884ac6dd8a3748aa730a403b112af092ac8d04edc4e69c8f464e5f47fefa1481f29e0f1bc6dc8930f9fb82dca282"
    # v3.0.46 is the last release that published kubescape-ubuntu-latest and
    # kubescape-arm64-ubuntu-latest instead of kubescape_${VERSION}_linux_${ARCH}.
    ["3.0.46/amd64"]="33e3eefacd3d1161e4220685a6ae63bd12410de7cdae0cfeca8dc1400c4ab2616eeaddaeabf4e269594008e24c9d5398f090dc38b0fe98c83998c775f5a23f0d"
    ["3.0.46/arm64"]="a75ce815532ce69567adf1e37176bda4f5356da5ca10647114c5fcc5f703738f5dcc7f78fa9358235c9519f3ab341343a3c1d78be269cfd35607cbb8a5f876b5"
    ["3.0.45/amd64"]="75007d5f4af00ce29eb20e658f1ee092f785a1cd951bc496bfc98e48466406ac237f73e021827a5dc4d46625aa90b28de88e9242e5e767bfcca79c742827c5a1"
    ["3.0.45/arm64"]="190820a7826e0c6de271fbd7f31a42154783c1db6dfee71f697b404e0ace35361308dda975f3f8ef6f00160009db2b63c31c5a10f903a7f945eccfae335ed614"
    ["3.0.44/amd64"]="f1981bc4b1d30603ca2b24c2bee2e93a2e5ee86666fbdfafa1f4b44c4f63def706f0744665a6a0bfd4762eb4fe3146f795ce1a6792794d05111b553d17d936d9"
    ["3.0.44/arm64"]="e0d1707b94bbf8802a3498b003fc56f23f5887246e14a2a22279b9f920e7e08967b9d755257cb30046068aca9613276bbae36a15d88fd26ac50c7f83b780a8d8"
    ["3.0.43/amd64"]="11a9b351babf3a709ff2765c1933795a01075d36c3ae6a08883cd70bad0c2f0739f0ea26603ea9df6b7dbed6a6f76ce4ef4cafa220c7612caf07226569b31b46"
    ["3.0.43/arm64"]="777885e08fce7307663b5e4e1a594caf066f63c143b2e0034c0ffb8bb92b7ef5e9407e90144c295c1dfa30da6061919899f1b7c311ee8b10a7411390e5266f7b"
    ["3.0.42/amd64"]="af626e5ce3c78837ca52670bd206259da93010e6e4e476e254f07849493d1bcf5038f180c3104d9acde77877478fc1ff351a054462b3de2aa4c60d167bfcffe7"
    ["3.0.42/arm64"]="2c016bc2006020cda0cbd6c9abc83a9949f0504829bf9f945cee7e3c1f1e4d8dd7b999795142d3c5375b9422e6174ce4a73870d8e3b7c125170ff1373f52567b"
    ["3.0.41/amd64"]="77ad2135b46367494834496996c5a605c11befcc8cb4e17cbe04fc4cf9d215d28e3676333c4f61a06c98d28a1c4742fd3f6bd159cc5d5c543dda041c514fb901"
    ["3.0.41/arm64"]="7ac0d874ac2e66ff77fdfe1df44e92ab2c19ddc38c5df347e9296225dacfc7d2249f8e1898f63cba91c6b6e7168f74f57256b05cdc31223a30b4adca9691465c"
    ["3.0.40/amd64"]="df3b9f891a3b557798ef083e0e18eb533bb36f8e1ec856e61280b75d055f52ac9555d32c34b2908ef19acc89ef50b2d4e69316bbce95261d6356242e0a216532"
    ["3.0.40/arm64"]="09cecbd052d6f06c1763e93f7d8d255bd5e6fafacb0743900c4f133d152b3d501b720c565654d463ce4cb1d5f54c576d1d1eb60c4c6d8b7554460a85adafdcfe"
    ["3.0.39/amd64"]="496edf0e7f825f5eb5d5b275fd750e139ba9c06f948532bfd803331e81f231aa8accbba392ee57954fb126a41e5236d929f64d3923d60c070879e5aeecb51861"
    ["3.0.39/arm64"]="af79a38852e2ec99761ea79f5608b8adfaf14e12e30b3d7fb65820a28a8ff4fe21a0de9ff19203db92f4d88f33b3606740bbe92b086c431f8fd17b727e9c19a5"
    ["3.0.38/amd64"]="c493f1726df427602f34b01a33439331cce7491fd544cf3881b00191e3cd201c7df97c8d3ca3bb7b77feb259d8444211e125e2919d50577a3fd562c4d38ff3f9"
    ["3.0.38/arm64"]="0c6339b705cede6c0ee9b429c26ca7c544af1aacee148d8c1b6067f5d7eedd04acbd70c531259bf28e21dd3eec248e322edd71dc9b2ab96b09cafe978fc9874e"
    ["3.0.37/amd64"]="352fd9d4050308b8ce92d0bd123773a57fbdfbdc85cc8dd92f6d4ab9cea3c9206128a856c30faa62a0ea3d59624952546d1b226aa8aa5e4c3834e2c6c9c64330"
    ["3.0.37/arm64"]="d2d6f1ec468c645059f750612da05415f58c9b9374f09c6089c0f1c10fca2d9c77b64eb25c029ddc2469f1d4106b4717a251e8f0ae5ac55a65da479252ec9819"
    ["3.0.36/amd64"]="6e348781351d86a205ee2cbb93b96506d3c42d5fbe1d0fa1df17790e4702a76d3ae8c5554e4482a786f1d1585d78770f8d821626aead47c4baeb7dfd5c1e3cfb"
    ["3.0.36/arm64"]="3670eea75478805e294dd2b47f03041b3233b06deb81e7713ee5a1b8dc2b1a6676ea762b81c0634e8c272afe26d9480bea06818e98c6ec0fc7959dd97429d6e4"
    ["3.0.35/amd64"]="344f8fdde8695ab2b972e9f0381af8220d0cd4b22f1c076d4351ffb43fccb2138ab0711efebde375a63d0a6d92dcf7a3230181fa05de7c2407c2d28d8c412fe5"
    ["3.0.35/arm64"]="52e8bd72d0ba5282f8265c71e42e6eef2edd9360331bb0f75cba556c314f3b2ab2a0e452c8a16424d2a14f549f3c9a0ba175f2ef210b12948db08aaf3c4baf0a"
    ["3.0.34/amd64"]="6cc5559d629c33db11b46607d85b3eef418fc53b98ae378c46b41442a829dc44bd2b4ba0661891b9b5ac96ea2ffa3000b31f4e36ec10c42a650726dd92c73db2"
    ["3.0.34/arm64"]="5a10b92653940e56e049a3519b6efb2908fb32e9d57e582862e0634c4b615d31a6896f13447007f6d1f4f1b028847bafd7c127b3ecb5271923b6d745e09cf021"
    ["3.0.33/amd64"]="99acfab41d4cdff75c19175b9fc7bb8d156af45cd7d6b005742aa4202d1ffae77f941214eb24c01c53cc5fbd6684adaf504c60b33ea2e21b278826f37897385b"
    ["3.0.33/arm64"]="807e1d881306c2fa5c51c759e30af31d09b02d7c6e6d2528972c587c5935fc0dd3ae7cde67c11c2aa21fae253b89bcaa13fed729e6fb7725fba8e9ce398e782b"
    ["3.0.32/amd64"]="5b3b729a81f43376aba4e0ba0e119596d2e2cdb519eaaa8fd77a2c2547047c7971b1d7d74cc86342962d3099081b58aea87f2f82ee071c5d50a92eae70c12a56"
    ["3.0.32/arm64"]="189281b0ce48c16540a89709021694463e75c73a82fde4fb2412b1d41f94f474c4e9db188d750fe3b80755483354f9cacb75fce5e8c2a6ecbfae059556d18b56"
    ["3.0.31/amd64"]="97b43ed1f590f3059c4f63ca3fa1f6b9de60a9a68e1eddfb4fe1ce7efc7bdd13302be67d29dd6fd651cfb296facff4743bae3e02405e449ef3ea118dc5073057"
    ["3.0.31/arm64"]="cf78617275df4c7c49601cbf32c0a5f7029e7f86a5a7c5978f00583b365349e9771a306445a8782dd84399e81c2d6017cf3fc068a91d8dacc9f202f765c25de7"
    ["3.0.30/amd64"]="1320105e5c1f34b0dc5c58a3984bb72b01989f300f748ef242f337e23150f6a9d592c107f97da31757950ec055507bc33a8cc4c3ef808ce6d021b58c49d0ed72"
    ["3.0.30/arm64"]="7ef9fc7c55ea5428b4cb8ebda1abccdce8fd6185100abafe93a4e408c4453292441d5dabb6d5f9885ec410c7ca4f36b407ef05978df3588bb18584f0dd58f0dd"
    ["3.0.29/amd64"]="89750d8f4afb8c5ed90dd820d63b52c2e8dcc89758cf09babf36b4ed1ca044d11079d8b003ad5ecd2f859a2c4a97045f6208c4d33a8ec38f39aa10eef59e4efd"
    ["3.0.29/arm64"]="34f5c78d0e2b2db1c191f0d466081ec902dc08d6f0edaa25f7e21c83a913e26529fd63751992ee765786e77ec54bf4f054851b4b4c7574e47b3e25060693c8a6"
    ["3.0.28/amd64"]="8249c29729540951d1c014afaf19902a916d73687d2c5b8b208b56b119db5bd69588dc274a35617835dc577095dbab8ac67f253c9ce0845336ce03713a56d011"
    ["3.0.28/arm64"]="4029b4f5c6803102f4062bac6ea458b87edf666fe1d5083dedc09dd60952d6e27d32fbe3e69210e990da7fd0b60526b9a0628bc3f6b62cff33322c2af587af6e"
    ["3.0.27/amd64"]="bcc5ebb8b75b0c00a5a3189b9290c8a6c078e9a7c7de8119339943319bec26f1b059c1d81490e0ea35adb5d0ebfec2c06f25f49ad0a895e977ac58ae4d04b45d"
    ["3.0.27/arm64"]="c16f40c1355e3b282a6bd3e8d41a37f9d0ba74c79dbdd146d4e0cb62c3a8ef4ab9968fc4e5ec6731db0877ce35fdde09241d77f6f563364b5bcd977a7ed09ea0"
    # Version 3.0.26 was not released correctly.
    ["3.0.25/amd64"]="8fb63eb7956ac18f17af8db31077a3799a0ee63bd226e5861330cb182d730b7896eea2088aec9a6d6f9142b335e0482a9931a9b390cec8910759264f5ddb4979"
    ["3.0.25/arm64"]="60caa08faa9c5d8aef00fa130ff843eee562ea7f176aa1e8a3b956b7622dac199023b02171e73ddfde6e66774ad3c1f5abcea346812e14d917283d8eae54badf"
    ["3.0.24/amd64"]="0607b771049482c0a02b70a312d16e7491bdabe12f6f48c58637f3c766abcea33680c032445482dbb80381862058d87c94b985bcbcdd7d9b5676cf01a7c31b0d"
    ["3.0.24/arm64"]="35ae493cde013945e295cb0ab8dce65a85be305275bcb5b66d1d5ac9298d923164afe944177fef01ebbf68a54e0f771bc51c5213f3abe138733bf65e9d86cd3f"
    ["3.0.23/amd64"]="5c76639c5fd8eb6734b3b45469aeda132f1cb482471bceec420915a3c709343197151c3ee2065634fe290dec34fa856073f188075ffe29aa4f2666f06f00b0fa"
    ["3.0.23/arm64"]="b8c5081dbe31ef7a3207a520f08a6c9a3ce1ba1e2425bbc43806b24d888317ab9f2ea592605d8e2d98faf5215b5372f0f7b267d45eb984602dc6f57f813feb83"
    ["3.0.22/amd64"]="f590da75030dd9301b35c14386858d42b94909cd4732888597223968888f57090efb1b8d17ca3599ff071ae249dc1f1fb34b866d11a97e72e3df4ada732a3148"
    ["3.0.22/arm64"]="b6ad0c5df29887629a48ab51f855f01fb6d39c84593c9cca47a36bd22207e37582b4a06861419412dd76d17b84a0174a34a626d3bc0db8a8a1b65ed484104a40"
    ["3.0.21/amd64"]="8e10a333a08de396c17fc9ce36d406b2a98c8052a6cb5f4a74e9884e87acd0c8e55655678026d6088ca7f6a98d0edab663fe50b2ba63859d1cc0757611eeca33"
    ["3.0.21/arm64"]="475d7bdedd7d468d267febd52af3572b24b16e38cc373cbfc24e8bdd11208aab023b64a164875d5793245058c7cb85c8a2da28785ea47f588cb3915776443d2b"
    ["3.0.20/amd64"]="cdb5e2b07c791939733e35841c3f60191b591a94967a7127d5f5c1c8aa38218863b6e0fb43b9a440cc6a65b55f5107acc36a22cb2e69032466c4fdd62e040d7d"
    ["3.0.20/arm64"]="5fe71274ca4f2320be3326f6710c9e88d0195adb702f7c915c77a022d3455f2710e318583adf98d42f479d57dddbe82905dd98b96274ed61d98836f85bf77428"
    ["3.0.19/amd64"]="07c0fd0478835fd4a983c1c02aa1cfe7096129e1c46e24926aa9294d3bb5277b82fe1065fd72fc1f5f995801c872106386b6e4e574284f8284f2293f7be8f0d0"
    ["3.0.19/arm64"]="b7c1deb00f821d2f562df6cc9e51e54e72e0f2bbecf92055ec0dee920510a64e61ee438500455fb2f17ee10301f0eef0bff5988da86c09038566f92965de6f3c"
    ["3.0.18/amd64"]="877b42d2ff957b96d61306fcabba9ea2609a14ed88cc44feb02900b00e38bcaa82de1cbb342f5ea858009c9b958da08afa503946e76bf681511a8cae8d65ff12"
    ["3.0.18/arm64"]="dc4bbef875bf6d7fbd519f75415b3508de6e16937ca5f2b7c4780d48667713dbcdf2c5f03ed62dad218a2c5a54618b746115cff18aa58085257ab0255c0ed5f4"
    ["3.0.17/amd64"]="cb1f45dfd445a56acbc10ce2dd25d156c98c576c6d626215773f9905de8b4d63de870833b313fafbfadb9e8a5d774059ee2cc964847f147b4f8d75272d443fed"
    ["3.0.17/arm64"]="fdeba94449a286b77379629d3d7e1ec9e10324cac7c4e4836e77787a0f6a3593c00e3850a982b41995988edc0c1f1e12d7691f61db10e8721dd92211785a0854"
    ["3.0.16/amd64"]="a59b60d1cca7aa3dafca728b5d98dcb01b9e790f619c5397e7ec7027e915bbcdea2593942beb7f4dfe816a0bfeb74dff02b0ebc8640a75cf7556cc8e02623e8c"
    ["3.0.16/arm64"]="64bfe96a4d1340df99117a592ddd7639146171a26dbbf89cff01876d1982adcdb9b72391021b7cc271d0bdc8d11036a0dea655debca5e993d8b2d342eeefdf25"
    ["3.0.15/amd64"]="d263406c7d9bcfd726a3310f38dc33970a15e8863af60d0b2d01ee0d02e834436dd677cdd25ff3e045bd4ffb09f554f2bdba10b9be91f7a903ea7b80513eba0c"
    ["3.0.15/arm64"]="d7b5830a1f45118ab08126b6eb48086d0a92bb388ad68ecffec491588c42ce270a7d81c3cecdd0a40d2e961df795632ae9cd17d834607fcdd1c729255eb37795"
    ["3.0.14/amd64"]="d373c09d74be061581493919cf08f170932d8da14018b19381c73af2c9d8bbee64b150f65d7937da961674fc5581e64dad3f0b6ce2df11c408cd282ee375ff14"
    ["3.0.14/arm64"]="133ca9a11290bc703fab58e035f63a1a69c967551c4dec21ccfa963f5a977b4de6fbddde231af60f35169659dc8f623f9d8b8d97203f8154ab2b3bfc6df9c8d7"
    ["3.0.13/amd64"]="1a9314ca7bb581750ae6182798532f2d0f2a16cbf5e5809f760cfc0d23d2a7106370c1cedd546cd69f6470966ffa7205e8adc55c077a05d3a935bd57dc0b0d90"
    ["3.0.13/arm64"]="8b9f639ad31a5265dc6256a118e00fbbe36a8f89c0c595c77ac689cfddeeb4174fcb76498a9eef500043780505c4402e4077f0cef14fc6dd5d444b5348499ee0"
    ["3.0.12/amd64"]="4e5860c221dfdfc76da074b6c1f711b245053f8584f55070ce6899246b79c47f12d95b120f948bca72332dd399f7cc393f29e59d20062cc82a8e08b0c480d0e7"
    ["3.0.12/arm64"]="3f498713029ece96568cf60aee95638f05889b5c521e0f79582e4a6f1203de2a3ae9940b32ba9eff6f7fd72c748d095bb9be34c50a75dcb71969d49e401f2458"
    ["3.0.11/amd64"]="9ac830f3104e7374cd04e4b5a3fb453be9e97e90b9dc7ca4fb51c93eee64b66c1fe9b8cba3e8b3be832bd418755568170b3b8addf5b29ce39d827c96414e2c44"
    ["3.0.11/arm64"]="96a8d63288effc0d70c0b0642b5f107d0a2dc8a182bd6f6fc9fcbda40ea8066a79849c09eab4ef3541e26a4ad7ef3c7675c4ea1d50a320fafd3cbbc6ffb2202b"
    ["3.0.10/amd64"]="7dce5c7ddbde4896b853e3db62454817c299fda85cf21f6676a4282ada5feba35158a63f4dbc57f0260ce4e704262df04384c82035ff6f9f09f23c6f9f9037f8"
    ["3.0.10/arm64"]="bbcad6a2f6f094d1ac1295b66228d9dbd082ac1a5a3052dd48b870a0608af441ef5de666b4af6faf0c5e726616c1afe6cbbec9c0935a4524b2a77f74f74b905b"
    ["3.0.9/amd64"]="482dae8f82ec87df036680525ba62e9548562c3af558be6b1a08f46bb0b1a3f761d66ab72dd2e3aad151dd1795584889164f787a326bc7ca14487d08d8053122"
    ["3.0.9/arm64"]="9e0c818fee4b5621b363e70df6ba4b6ab1f17e5ed48396e87bf58d38eeadebd0928446221fafce74059b00edc880fcc4234164ac5f725816117410bf7b6c1da8"
    ["3.0.8/amd64"]="beeb01876af92f8906c42d24e06928402f14d464e2a386d5ad48a157ecb13e0472b5c01e030239317a109d50a591a5eee948a22f8d956f41d158e18bd1e9a5a8"
    ["3.0.8/arm64"]="0d03f00aed9be7176a6cb3fbf9afdb1df1110956f8f17ffe5ff5c6df6b06ddcc7ccc9fa6fa0b136192779aded225716ca9d16f884858cdb7dca684648c3d06f4"
    ["3.0.7/amd64"]="3af32e386fcd68338c5e8234d014ae8fe9830e9ad4dfc9a8baf4d67e5befa70cf949bcb23aee8c0c9aea18ca63e6b137b4a226a60a2bef7016afb7fa27324037"
    ["3.0.7/arm64"]="3bd9446cd02def7c368724d09e2df09b296f5afc8eb1b5adf43f8ddb278a580c27e15ddf5f132159f3c89346159b4707862a676ba32797b2bfbb8613ffaef65b"
    ["3.0.6/amd64"]="1bc7cb3f3271d018381b99a1994ea1ad21be2925648db55eee315ffb0b994dbc7e71cbf4ad6329b26460c716bf628060413ca83fd418319990ef64d9b4e3b8cb"
    ["3.0.6/arm64"]="446076f2a90688fd901ccb082b6779db2da3a881f91c6831f668e2b86b82f6b465e68b87a4bfd7ecdab19d6a24aa97bc9d6a4d1bab9108fe9e69d20a84d6d728"
    ["3.0.5/amd64"]="c47b39559c08ad5429bf283bc300958b61616ee41487407a695f8493be6113eb1bd746e77f5ebb172bda79ada07253aea1161e40c19e19f12553e360268de3f5"
    ["3.0.5/arm64"]="a0779e16a9445b69cc68ddceb82ae0c715932f4c36fbe4241931e15d1997df3de2390bdc0b5cba5b245f4d8c3daa1ed124f6e39564e839b55bf6425b17fdd149"
    ["3.0.4/amd64"]="caa241140e4e6a39827a554d402024ef3d1047bdb3edd5ec86dda184a407063399ac489a9873b905c330814c145054f537a7f61be1354d3e409df22586119063"
    ["3.0.4/arm64"]="96244b0127ae08c9e6f9e23bd3fc18ff86916a558d010ac118aebf85c8062729d6f83fbe825340f2a3776d7ff281132aae4e9cba373479af0ad8f0cbad2474ca"
    ["3.0.3/amd64"]="eb8a3522b178baea91c018be8163c251a2b43d23ae2031a1989627c0b929d1bd7ea7266f28800006f6a4af6691b9bc0d2758b96187ebdba49a3b60ae44c1546b"
    ["3.0.3/arm64"]="3b3e5b3b2b207d64760b713d32f4b30736e4af1e0058790ad939fad5b34da381e84d82f0bb0edc3f0b7fd49cde19dbe124d398161fd79995acb12e417a9b7ea3"
    # Version 3.0.2 was not released correctly.
    ["3.0.1/amd64"]="e1e6ea8f99dfbadf19b863c7dd3f186aa535689bcdfede50c1db04fc3510bc9b9a79922005d50c0967de59eb8dc48f745d324a78dafb1c62dbdc0aeefbee860b"
    ["3.0.1/arm64"]="8ed5bdec4ae8f4c0ce98439ee39e5083a15d2e75199b13ce5a22ae69699ebfcb72ecc088627b3d1fe5cb64b2c7661feab2e4d9dfa20df2fb8fc88e9155ef3398"
    ["3.0.0/amd64"]="89b4cfea8a545725828644aed8381b7e85eb38e63a8bf63c855101fd34cfc397be08c875b8dbb8a8c7e8c02041231a4b330691cff52b64f7de11ecc6af1d9a6d"
    ["3.0.0/arm64"]="8bed2ab61d2be9838f1b56779890c8d8e583075c0b32276bc78b0d6be1853875276ca1bd1e0eca10bbd4440a73b812934ae0796a7ddd75ce92b7c88ce1462c7a"
)
# <<< checksum table <<<

orb_install_main
