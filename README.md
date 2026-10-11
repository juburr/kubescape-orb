<div align="center">
  <img align="center" width="320" src="assets/logos/kubescape-orb.png" alt="Kubescape Orb">
  <h1>CircleCI Kubescape Orb</h1>
  <i>Harden your Kubernetes cluster with this orb for simplifying Kubescape installation and use within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/kubescape-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/kubescape-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/kubescape-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/kubescape-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/kubescape-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial orb used to install Kubescape in your CircleCI pipeline and scan for security issues in Kubernetes. Contributions are welcome!

Scan Kubernetes YAML files and Helm charts in your CI pipeline using frameworks such as NSA, MITRE, SOC2, CIS, and more!

## Features
### **Secure By Design**
- **Least Privilege**: Installs to a user-owned directory by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded binaries using SHA-512. Fails closed by default: a Kubescape version this orb has no checksum for is refused, not installed unverified. See [Checksum Verification](#checksum-verification).
- **Provenance**: Installs directly from Kubescape's official [releases page](https://github.com/kubescape/kubescape/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

Info for security teams:
- Required external access to allow, if running a locked down, self-hosted CircleCI pipeline on-prem:
  - `github.com`: For download and installation of the Kubescape tool.

## Example Usage

The following example assumes a Helm chart was built in a previous job, and saved to the workspace. `helm_scan_framework` renders the chart with `helm template`, so the executor needs Helm on its `PATH`; `cimg/deploy` includes it, `cimg/base` does not.

This example uses the NSA framework for demonstration purposes, but many organizations will elect to use "all" (the default, if not supplied).

```yaml
  version: 2.1

  orbs:
    kubescape: juburr/kubescape-orb@latest

  jobs:
    helm_scan:
      docker:
        - image: cimg/deploy:2026.10
      steps:
        - attach_workspace:
            at: /home/circleci/project/helm_charts
        - kubescape/install:
            version: "4.0.15"
        - kubescape/helm_scan_framework:
            chart_path: /home/circleci/project/helm_charts/myservice-1.0.0.tgz
            framework: nsa
            output_file: myservice_nsa_scan.json
            output_format: json
```

## Kubescape Versions

v0.4.0 of this orb changed the default Kubescape `version` from 3.0.38 to 4.0.15, a new major version. Pin `version` on the `install` command, as in the example above, so Kubescape only changes when you decide to rather than whenever the orb is upgraded.

CI runs `helm_scan_framework` with Kubescape 3.0.38 and 4.0.15 on amd64, and installs and scans with both on arm64. Both versions accept the same flags and framework names. Both exit 0 when controls fail, since this orb doesn't pass a compliance or severity threshold, and exit non-zero on errors: an unknown framework, a failed policy download, or a chart with no resources the framework covers. Differences that matter when moving from 3.x to 4.x:

| | Kubescape 3.x | Kubescape 4.x |
| --- | --- | --- |
| `output_format` | `pretty-printer`, `json`, `junit`, `prometheus`, `pdf`, `html`, `sarif`. Other values silently produce pretty-printer output. | Every format the orb accepts, adding `csv`, `markdown`, `yaml`, `gitlab-sast`, `github-actions`, `policyreport` and `exceptions`. |
| SARIF output | Valid, but contains no results for scanned charts | Includes results |
| `output_file` extension | Appended when missing for `json`, `junit` (`.xml`), `sarif`, `html` and `pdf` | Appended when missing for every format, e.g. `.txt` for `pretty-printer` and `prometheus` |
| JSON report | Baseline | Same `summaryDetails` structure; adds `namespaceSummaries`, drops `jobID`, `paginationInfo` and `customerGUIDGenerated` |
| Network access during scans | GitHub, to download policies | GitHub, plus `tuf-repo-cdn.sigstore.dev`: 4.x verifies downloaded policies with Sigstore and fails the scan if it can't |

Give `output_file` the extension that matches `output_format` (see the parameter's description) so the report lands at exactly that path on either version. The `cis-eks-t1.2.0` and `cis-v1.23-t1.0.1` frameworks have been removed from Kubescape's policy library and fail on every Kubescape version, so `helm_scan_framework` no longer accepts them.

## Supported Platforms

Linux executors on `x86_64` (amd64) and `aarch64`/`arm64` (arm64), including CircleCI [Arm resource classes](https://circleci.com/docs/using-arm/). The `install` command picks the Kubescape release asset for the architecture reported by `uname -m` and verifies it against that architecture's SHA-512 checksum. Any other operating system or architecture fails the install rather than installing a binary that can't run.

The download cache is keyed by Kubescape version and executor architecture, so amd64 and arm64 jobs never share a cached binary. On executors whose `PATH` doesn't already include `install_path` (for example, machine executors), `install` adds it for later steps through `BASH_ENV`.

## Checksum Verification

The `install` command checks the downloaded Kubescape binary against a SHA-512 lookup table built into the orb, with one entry per Kubescape version and architecture. The `verify_checksums` parameter controls what happens:

| Value | Version in the orb's table | Version not in the table |
| --- | --- | --- |
| `strict` (default) | Verified; install fails on mismatch | Install fails before anything is downloaded |
| `known_versions` | Verified; install fails on mismatch | Installed **unverified**, with a warning |
| `false` | Not verified | Installed **unverified** |

The table covers every Kubescape release this orb version knows about, including the default `version`. If you pin a Kubescape release newer than this orb, `strict` fails until the orb is upgraded. Upgrade the orb (or open a PR adding the checksum, generated with `src/scripts/install_hash.sh`) rather than opting out. `known_versions` and `false` remain available for cases where you accept running an unverified binary.

> **Changed in v0.5.0:** the default was previously `known_versions`, which installed unlisted versions without verification. Pipelines that pin a Kubescape version newer than the orb's table now fail until they upgrade the orb or set `verify_checksums: known_versions` explicitly.
