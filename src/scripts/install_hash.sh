#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh. Prints one entry per supported architecture.

set -e
set +o history

# Fetch CLI arguments
# Can also be set as environment variables.
while getopts :v: flag
do
    case "${flag}" in
        v) VERSION=${OPTARG};;
        *) echo "Invalid option: -${OPTARG}" >&2; exit 1;;
    esac
done

# Validate input arguments
VERSION="${VERSION#v}"
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

# Resolve the GitHub release asset name. GoReleaser renamed Linux binaries
# starting with v3.0.47 (kubescape-ubuntu-latest -> kubescape_${VERSION}_linux_amd64,
# kubescape-arm64-ubuntu-latest -> kubescape_${VERSION}_linux_arm64).
kubescape_linux_asset() {
    local version="$1"
    local arch="$2"
    if printf '%s\n%s\n' "3.0.47" "${version}" | sort -C -V; then
        echo "kubescape_${version}_linux_${arch}"
    elif [[ "${arch}" == "arm64" ]]; then
        echo "kubescape-arm64-ubuntu-latest"
    else
        echo "kubescape-ubuntu-latest"
    fi
}

download() {
    local url="$1"
    local output="$2"
    if command -v wget &> /dev/null; then
        wget "${url}" -O "${output}" -q
    elif command -v curl &> /dev/null; then
        curl -fsSL "${url}" -o "${output}"
    else
        echo "ERROR: Neither wget nor curl is available. Please install one of them." >&2
        exit 1
    fi
}

RELEASE_URL="https://github.com/kubescape/kubescape/releases/download/v${VERSION}"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Kubescape publishes SHA-256 sums for most releases, either in a combined
# checksums.sha256 file (newer releases) or as <asset>.sha256 (older ones).
# When available, confirm the download matches before printing its SHA-512.
download "${RELEASE_URL}/checksums.sha256" "${WORK_DIR}/checksums.sha256" 2> /dev/null || true

# Download the specified version and get the SHA-512 checksum of
# the kubescape binary for each architecture. Suppress output for readability;
# this is a dev script, so simply re-enable output if you need to debug anything.
for ARCH in amd64 arm64; do
    ASSET_NAME=$(kubescape_linux_asset "${VERSION}" "${ARCH}")
    download "${RELEASE_URL}/${ASSET_NAME}" "${WORK_DIR}/kubescape"

    UPSTREAM_SHA256=""
    if [[ -s "${WORK_DIR}/checksums.sha256" ]]; then
        UPSTREAM_SHA256=$(awk -v asset="${ASSET_NAME}" '$2 == asset { print $1 }' "${WORK_DIR}/checksums.sha256")
    fi
    if [[ -z "${UPSTREAM_SHA256}" ]] && download "${RELEASE_URL}/${ASSET_NAME}.sha256" "${WORK_DIR}/asset.sha256" 2> /dev/null; then
        UPSTREAM_SHA256=$(awk '{ print $1; exit }' "${WORK_DIR}/asset.sha256")
    fi
    if [[ -n "${UPSTREAM_SHA256}" ]]; then
        ACTUAL_SHA256=$(sha256sum "${WORK_DIR}/kubescape" | awk '{ print $1 }')
        if [[ "${ACTUAL_SHA256}" != "${UPSTREAM_SHA256}" ]]; then
            echo "ERROR: ${ASSET_NAME} does not match the SHA-256 published with the release." >&2
            exit 1
        fi
    else
        echo "WARN: No upstream SHA-256 published for ${ASSET_NAME}; SHA-512 is unverified against the release." >&2
    fi

    CHECKSUM=$(sha512sum "${WORK_DIR}/kubescape" | awk '{ print $1 }')
    echo "[\"${VERSION}:${ARCH}\"]=\"${CHECKSUM}\""
    rm "${WORK_DIR}/kubescape"
done
