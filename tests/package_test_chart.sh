#!/usr/bin/env bash
#
# Packages the chart from `helm create` that the GitHub workflow
# (.github/workflows/actions.yml) scans, as the setup-test-chart command does
# in test-deploy.yml. Installs a pinned, checksum-verified Helm first when the
# runner doesn't ship one, outside the orb's default install path, and adds it
# to GITHUB_PATH for later steps.
#
# Usage: tests/package_test_chart.sh DIR
#   writes DIR/myservice-0.1.0.tgz

set -euo pipefail

DIR=${1:?usage: tests/package_test_chart.sh DIR}

if ! command -v helm > /dev/null; then
    HELM_VERSION="3.19.0"
    case "$(uname -m)" in
        x86_64) HELM_ARCH="amd64"; HELM_SHA256="a7f81ce08007091b86d8bd696eb4d86b8d0f2e1b9f6c714be62f82f96a594496" ;;
        aarch64) HELM_ARCH="arm64"; HELM_SHA256="440cf7add0aee27ebc93fada965523c1dc2e0ab340d4348da2215737fc0d76ad" ;;
        *)
            echo "ERROR: unsupported architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac
    WORK=$(mktemp -d)
    trap 'rm -rf "${WORK}"' EXIT
    curl -fsSL --proto '=https' -o "${WORK}/helm.tar.gz" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-${HELM_ARCH}.tar.gz"
    echo "${HELM_SHA256}  ${WORK}/helm.tar.gz" | sha256sum -c -
    mkdir -p "${HOME}/.local/helm/bin"
    tar -xzf "${WORK}/helm.tar.gz" -C "${WORK}" "linux-${HELM_ARCH}/helm"
    mv "${WORK}/linux-${HELM_ARCH}/helm" "${HOME}/.local/helm/bin/helm"
    export PATH="${HOME}/.local/helm/bin:${PATH}"
    if [[ -n "${GITHUB_PATH:-}" ]]; then
        echo "${HOME}/.local/helm/bin" >> "${GITHUB_PATH}"
    fi
fi
helm version
mkdir -p "${DIR}"
cd "${DIR}"
helm create myservice
helm package myservice
