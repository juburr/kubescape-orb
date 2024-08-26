#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Kubescape installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of kubescape-ubuntu-latest
declare -A sha512sums
sha512sums=(
    ["3.0.16"]="a59b60d1cca7aa3dafca728b5d98dcb01b9e790f619c5397e7ec7027e915bbcdea2593942beb7f4dfe816a0bfeb74dff02b0ebc8640a75cf7556cc8e02623e8c"
    ["3.0.15"]="d263406c7d9bcfd726a3310f38dc33970a15e8863af60d0b2d01ee0d02e834436dd677cdd25ff3e045bd4ffb09f554f2bdba10b9be91f7a903ea7b80513eba0c"
    ["3.0.14"]="d373c09d74be061581493919cf08f170932d8da14018b19381c73af2c9d8bbee64b150f65d7937da961674fc5581e64dad3f0b6ce2df11c408cd282ee375ff14"
    ["3.0.13"]="1a9314ca7bb581750ae6182798532f2d0f2a16cbf5e5809f760cfc0d23d2a7106370c1cedd546cd69f6470966ffa7205e8adc55c077a05d3a935bd57dc0b0d90"
    ["3.0.12"]="4e5860c221dfdfc76da074b6c1f711b245053f8584f55070ce6899246b79c47f12d95b120f948bca72332dd399f7cc393f29e59d20062cc82a8e08b0c480d0e7"
    ["3.0.11"]="9ac830f3104e7374cd04e4b5a3fb453be9e97e90b9dc7ca4fb51c93eee64b66c1fe9b8cba3e8b3be832bd418755568170b3b8addf5b29ce39d827c96414e2c44"
    ["3.0.10"]="7dce5c7ddbde4896b853e3db62454817c299fda85cf21f6676a4282ada5feba35158a63f4dbc57f0260ce4e704262df04384c82035ff6f9f09f23c6f9f9037f8"
    ["3.0.9"]="482dae8f82ec87df036680525ba62e9548562c3af558be6b1a08f46bb0b1a3f761d66ab72dd2e3aad151dd1795584889164f787a326bc7ca14487d08d8053122"
    ["3.0.8"]="beeb01876af92f8906c42d24e06928402f14d464e2a386d5ad48a157ecb13e0472b5c01e030239317a109d50a591a5eee948a22f8d956f41d158e18bd1e9a5a8"
    ["3.0.7"]="3af32e386fcd68338c5e8234d014ae8fe9830e9ad4dfc9a8baf4d67e5befa70cf949bcb23aee8c0c9aea18ca63e6b137b4a226a60a2bef7016afb7fa27324037"
    ["3.0.6"]="1bc7cb3f3271d018381b99a1994ea1ad21be2925648db55eee315ffb0b994dbc7e71cbf4ad6329b26460c716bf628060413ca83fd418319990ef64d9b4e3b8cb"
    ["3.0.5"]="c47b39559c08ad5429bf283bc300958b61616ee41487407a695f8493be6113eb1bd746e77f5ebb172bda79ada07253aea1161e40c19e19f12553e360268de3f5"
    ["3.0.4"]="caa241140e4e6a39827a554d402024ef3d1047bdb3edd5ec86dda184a407063399ac489a9873b905c330814c145054f537a7f61be1354d3e409df22586119063"
    ["3.0.3"]="eb8a3522b178baea91c018be8163c251a2b43d23ae2031a1989627c0b929d1bd7ea7266f28800006f6a4af6691b9bc0d2758b96187ebdba49a3b60ae44c1546b"
    # Version 3.0.2 was not released correctly.
    ["3.0.1"]="e1e6ea8f99dfbadf19b863c7dd3f186aa535689bcdfede50c1db04fc3510bc9b9a79922005d50c0967de59eb8dc48f745d324a78dafb1c62dbdc0aeefbee860b"
    ["3.0.0"]="89b4cfea8a545725828644aed8381b7e85eb38e63a8bf63c855101fd34cfc397be08c875b8dbb8a8c7e8c02041231a4b330691cff52b64f7de11ecc6af1d9a6d"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the kubescape tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f kubescape.tar.gz ]]; then
    tar xvzf kubescape.tar.gz kubescape
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f kubescape ]]; then
    wget "https://github.com/kubescape/kubescape/releases/download/v${VERSION}/kubescape-ubuntu-latest" -O kubescape
    tar cvzf kubescape.tar.gz kubescape
fi

# An kubescape binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "kubescape" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of kubescape
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv kubescape "${INSTALL_PATH}/kubescape"
chmod +x "${INSTALL_PATH}/kubescape"
