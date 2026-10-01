#!/bin/bash

# Convenience script, not used by directly by the production orb, but
# for development purposes when adding SHA-512 checksums to the lookup
# table in install.sh.

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
if [[ -z "${VERSION}" ]]; then
  echo "Must specify a version number."
  echo "Usage: $0 -v 1.0.0"
  echo "Alternatively: VERSION=1.0.0 $0"
  exit 1
fi

# Resolve the GitHub release asset name. GoReleaser renamed Linux binaries
# starting with v3.0.47 (kubescape-ubuntu-latest -> kubescape_${VERSION}_linux_amd64).
kubescape_linux_amd64_asset() {
    local version="$1"
    if printf '%s\n%s\n' "3.0.47" "${version}" | sort -C -V; then
        echo "kubescape_${version}_linux_amd64"
    else
        echo "kubescape-ubuntu-latest"
    fi
}

ASSET_NAME=$(kubescape_linux_amd64_asset "${VERSION}")
DOWNLOAD_URL="https://github.com/kubescape/kubescape/releases/download/v${VERSION}/${ASSET_NAME}"

# Download the specified version and get the SHA-512 checksum of
# the kubescape binary inside. Suppress output for readability; this is
# a dev script, so simply re-enable output if you need to debug anything.
cd /tmp
if command -v wget &> /dev/null; then
    wget "${DOWNLOAD_URL}" -O kubescape -q
elif command -v curl &> /dev/null; then
    curl -fsSL "${DOWNLOAD_URL}" -o kubescape
else
    echo "ERROR: Neither wget nor curl is available. Please install one of them."
    exit 1
fi
CHECKSUM=$(sha512sum /tmp/kubescape | awk '{ print $1 }')
echo "[\"${VERSION}\"]=\"${CHECKSUM}\""
rm /tmp/kubescape
