<div align="center">
  <img align="center" width="320" src="assets/logos/kubescape-orb.png" alt="Kubescape Orb">
  <h1>CircleCI Kubescape Orb</h1>
  <i>Harden your Kubernetes cluster with this orb for simplifying Kubescape installation and use within CircleCI.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/kubescape-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/kubescape-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/kubescape-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/kubescape-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/kubescape-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This is an unofficial orb used to install Kubescape in your CircleCI pipeline and scan for security issues in Kubernetes. Contributions are welcome!

Scan Helm charts in your CI pipeline using frameworks such as NSA, MITRE, SOC2, CIS, and more!

## Features
### **Secure By Design**
- **Least Privilege**: Installs to a user-owned directory by default, with no `sudo` usage anywhere in this orb.
- **Integrity**: Checksum validation of all downloaded binaries using SHA-512. Fails closed by default: a Kubescape version this orb has no checksum for is refused, not installed unverified. See [Checksum Verification](#checksum-verification).
- **Provenance**: Installs directly from Kubescape's official [releases page](https://github.com/kubescape/kubescape/releases/) on GitHub. No third-party websites, domains, or proxies are used.
- **Confidentiality**: All secrets and environment variables are handled in accordance with CircleCI's [security recommendations](https://circleci.com/docs/security-recommendations/) and [best practices](https://circleci.com/docs/orbs-best-practices/).
- **Privacy**: No usage data of any kind is collected or shipped back to the orb developer.

Info for security teams: see [Network Access](#network-access) for the hosts to allow on locked-down or self-hosted runners, and [Running Offline](#running-offline) for scanning without network access.

## Example Usage

The following example assumes a Helm chart was built in a previous job, and saved to the workspace. `scan_helm_chart` renders the chart with `helm template`, so the executor needs Helm on its `PATH`; `cimg/deploy` includes it, `cimg/base` does not.

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
        - kubescape/scan_helm_chart:
            chart: /home/circleci/project/helm_charts/myservice-1.0.0.tgz
            framework: nsa
            output_file: myservice_nsa_scan.json
            output_format: json
```

### `scan_helm_chart` parameters

| Parameter | Default | Description |
| --- | --- | --- |
| `chart` | | Chart to scan: anything `helm template` accepts, such as a chart directory, a packaged `.tgz` file, a `repo/chart` reference, or an `oci://` URL. Required. |
| `framework` | `all` | The one framework to scan with, such as `nsa`, `mitre`, `soc2` or `cis-v1.12.0`, or `all`. |
| `output_file` | | Path of the report file. Use the extension that matches `output_format` (see [Kubescape Versions](#kubescape-versions)). Required. |
| `output_format` | `json` | Report format, Kubescape's `--format`, such as `json`, `sarif`, `junit` or `html`. |
| `release_namespace` | `kubescape-orb` | Namespace passed to `helm template`, which only sets `.Release.Namespace` while rendering. Nothing is deployed. |
| `verbose` | `true` | Include passed resources and controls in the report, not only failed ones (Kubescape's `--verbose`, which is off by default in Kubescape itself). It doesn't change the log level. |
| `artifacts_dir` | | Directory created with `kubescape download artifacts --output <dir>`, to scan without downloading policies. See [Running Offline](#running-offline). |

Environment variables are expanded in `chart`, `output_file`, `release_namespace` and `artifacts_dir`.

## Upgrading

The next release renames the scan command and three of its parameters. Update your config as follows:

| Old | New |
| --- | --- |
| `helm_scan_framework` command | `scan_helm_chart` command |
| `helm_scan_framework.chart_path` | `scan_helm_chart.chart` |
| `helm_scan_framework.namespace` | `scan_helm_chart.release_namespace` |
| `helm_scan_framework.artifacts_path` | `scan_helm_chart.artifacts_dir` |

`framework`, `output_file`, `output_format` and `verbose` keep their names and behavior.

## Kubescape Versions

v0.4.0 of this orb changed the default Kubescape `version` from 3.0.38 to 4.0.15, a new major version. Pin `version` on the `install` command, as in the example above, so Kubescape only changes when you decide to rather than whenever the orb is upgraded.

CI runs `scan_helm_chart` with Kubescape 3.0.38 and 4.0.15 on amd64, and installs and scans with both on arm64. Both versions accept the same flags and framework names. Both exit 0 when controls fail, since this orb doesn't pass a compliance or severity threshold, and exit non-zero on errors: an unknown framework, a failed policy download, or a chart with no resources the framework covers. Differences that matter when moving from 3.x to 4.x:

| | Kubescape 3.x | Kubescape 4.x |
| --- | --- | --- |
| `output_format` | `pretty-printer`, `json`, `junit`, `prometheus`, `pdf`, `html`, `sarif`. Other values silently produce pretty-printer output. | Every format the orb accepts, adding `csv`, `markdown`, `yaml`, `gitlab-sast`, `github-actions`, `policyreport` and `exceptions`. |
| SARIF output | Valid, but contains no results for scanned charts | Includes results |
| `output_file` extension | Appended when missing for `json`, `junit` (`.xml`), `sarif`, `html` and `pdf` | Appended when missing for every format, e.g. `.txt` for `pretty-printer` and `prometheus` |
| JSON report | Baseline | Same `summaryDetails` structure; adds `namespaceSummaries`, drops `jobID`, `paginationInfo` and `customerGUIDGenerated` |
| `--verbose` with a terminal on stdin (as in CircleCI steps) | Works | Panics while printing results (exit 2). `scan_helm_chart` runs Kubescape with stdin redirected from `/dev/null`, so it is unaffected; do the same if you run `kubescape scan --verbose` in your own steps. |
| Network access during scans | GitHub, to download policies | GitHub, plus `tuf-repo-cdn.sigstore.dev`: 4.x verifies downloaded policies with Sigstore and fails the scan if it can't |

Give `output_file` the extension that matches `output_format` (see the parameter's description) so the report lands at exactly that path on either version. The `cis-eks-t1.2.0` and `cis-v1.23-t1.0.1` frameworks have been removed from Kubescape's policy library and fail on every Kubescape version, so `scan_helm_chart` no longer accepts them.

## Supported Platforms

Linux executors on `x86_64` (amd64) and `aarch64`/`arm64` (arm64), including CircleCI [Arm resource classes](https://circleci.com/docs/using-arm/). The `install` command picks the Kubescape release asset for the architecture reported by `uname -m` and verifies it against that architecture's SHA-512 checksum. Any other operating system or architecture fails the install rather than installing a binary that can't run.

The download cache is keyed by Kubescape version, executor architecture and home directory, so amd64 and arm64 jobs never share a cached binary. On executors whose `PATH` doesn't already include `install_path` (for example, machine executors), `install` adds it for later steps through `BASH_ENV`.

## Checksum Verification

The `install` command checks the downloaded Kubescape binary against a SHA-512 lookup table built into the orb, with one entry per Kubescape version and architecture. The `verify_checksums` parameter controls what happens:

| Value | Version in the orb's table | Version not in the table |
| --- | --- | --- |
| `strict` (default) | Verified; install fails on mismatch | Install fails before anything is downloaded |
| `known_versions` | Verified; install fails on mismatch | Installed **unverified**, with a warning |
| `false` | Not verified | Installed **unverified** |

The table covers every Kubescape release this orb version knows about, including the default `version`. If you pin a Kubescape release newer than this orb, `strict` fails until the orb is upgraded. Upgrade the orb (or open a PR adding the checksum, generated with `src/scripts/install_hash.sh`) rather than opting out. `known_versions` and `false` remain available for cases where you accept running an unverified binary.

> **Changed in v0.5.0:** the default was previously `known_versions`, which installed unlisted versions without verification. Pipelines that pin a Kubescape version newer than the orb's table now fail until they upgrade the orb or set `verify_checksums: known_versions` explicitly.

## Network Access

Hosts to allow (HTTPS, port 443) when running on a locked-down or self-hosted runner. They were confirmed by recording every connection Kubescape 3.0.38 and 4.0.15 made during `install` and `scan_helm_chart`.

| Host | Needed by | Purpose |
| --- | --- | --- |
| `github.com` | `install`, `scan_helm_chart` | Kubescape release download; at scan time, policy downloads from [kubescape/regolibrary](https://github.com/kubescape/regolibrary/releases) releases |
| `release-assets.githubusercontent.com` | `install`, `scan_helm_chart` | Where GitHub redirects release downloads |
| `objects.githubusercontent.com` | `install`, `scan_helm_chart` | GitHub's previous redirect target for release downloads; allow it as well so a change on GitHub's side doesn't break downloads |
| `tuf-repo-cdn.sigstore.dev` | `scan_helm_chart` with Kubescape 4.x | Sigstore trust root used to verify the downloaded policies' signatures. **Required:** when it is blocked, 4.x scans fail with `checksum verification failed ... failed to fetch Sigstore trusted root` |

Optional hosts. Kubescape carries on without them:

| Host | Used for | Notes |
| --- | --- | --- |
| `version-check.ks-services.co` | Kubescape's update check, on every scan | Set `KS_SKIP_UPDATE_CHECK: "true"` in the job's `environment` to turn it off. Where egress is silently dropped rather than rejected, it adds about a minute to each scan. |
| Registries of the chart's container images (e.g. `index.docker.io`, `auth.docker.io`) | Image signature controls in the `all`, `allcontrols` and `armobest` frameworks | Other frameworks don't contact registries |

`scan_helm_chart` renders the chart with `helm template`, which needs no network access for a chart directory or `.tgz` file. A `repo/chart` or `oci://` chart is downloaded from its chart repository or registry, so allow that host too. The orb doesn't install Helm, so `get.helm.sh` isn't needed unless you install Helm yourself.

## Running Offline

`scan_helm_chart` only needs the network to download Kubescape's policies (frameworks, control inputs, exceptions and attack tracks), and the chart itself when it comes from a chart repository or registry. To scan a local chart without network access, download the policies where access is available and pass the directory as `artifacts_dir`:

```yaml
  jobs:
    package_chart:
      docker:
        - image: cimg/deploy:2026.10
      steps:
        - checkout
        - run: helm package charts/myservice --destination /home/circleci/helm_charts
        - persist_to_workspace:
            root: /home/circleci
            paths:
              - helm_charts

    download_kubescape_artifacts:
      docker:
        - image: cimg/base:current-22.04
      steps:
        - kubescape/install:
            version: "4.0.15"
        # Kubescape 4.x verifies the policies' Sigstore signatures here.
        - run: kubescape download artifacts --output /home/circleci/kubescape-artifacts
        - persist_to_workspace:
            root: /home/circleci
            paths:
              - kubescape-artifacts

    helm_scan_offline:
      docker:
        - image: cimg/deploy:2026.10
      steps:
        - attach_workspace:
            at: /home/circleci
        # Downloads from GitHub; see below for runners with no route to it.
        - kubescape/install:
            version: "4.0.15"
        - kubescape/scan_helm_chart:
            artifacts_dir: /home/circleci/kubescape-artifacts
            chart: /home/circleci/helm_charts/myservice-1.0.0.tgz
            framework: nsa
            output_file: myservice_nsa_scan.json
            output_format: json

  workflows:
    scan:
      jobs:
        - package_chart
        - download_kubescape_artifacts
        # The scan job only sees workspace files (the chart and the
        # artifacts) from the jobs it requires.
        - helm_scan_offline:
            requires:
              - package_chart
              - download_kubescape_artifacts
```

With `artifacts_dir` set, Kubescape loads the policies from that directory and skips its update check, so scanning a chart directory or `.tgz` file opens no network connections. The exception is `all`, `allcontrols` and `armobest`, whose image signature controls still try to reach container registries and carry on when they can't. Download the artifacts with the same Kubescape version that scans, and refresh them regularly, since stale artifacts mean stale controls. You can also commit the directory to your repository instead of using a workspace.

`install` itself downloads Kubescape from GitHub. On a runner with no route to GitHub at all, bake Kubescape into the executor image instead, after checking its SHA-512 against the table in [`src/scripts/install.sh`](src/scripts/install.sh), and skip `install`.
