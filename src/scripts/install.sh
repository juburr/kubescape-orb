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

# Lookup table of sha512 checksums for Linux amd64 Kubescape binaries.
declare -A sha512sums
sha512sums=(
    ["4.0.15"]="eba2d3600d40fcafc54ad4bed6b8a4890dd8403b3093a3171c80c973969405a340f97a8c6bcbf0a3b574051fcf7d6d5c967eddb47b558e4f2d32050ff9a362f5"
    ["4.0.14"]="27cc519225dc0d53e2434e6c2c09ad8e94dbb05844a70f80316c5bbe9a13c9dfab25576c827b741745facfbb00202995e644d46adbf5556a5ca742347cbb6b6e"
    ["4.0.13"]="2260cf77dbc9c3664809823f1db6ca04eb87f173dd1a93e233277aa3a759d7e57e728d47c7f9e7e4306b2e8e3609add5fcd07a2495770ed403b9262d8f25b6eb"
    ["4.0.12"]="d9a268370e7542d0b55c7ab37837811e956a4e53ee021a0c07f4d939a5314b5cef5ae6d03659e5d343834983b22fb91adddc7110763b23f29fe80d8250f00b82"
    ["4.0.11"]="c06efbda7b376fa4df9545e738e56bed750068a98cadf9713acb0c5cd7a05cf10892fe36c02e38ca47e63c866149373be33c1a3d479b7e95049870245baba52b"
    ["4.0.10"]="223689b359b50ee5c5b55bacfda46374902e1af626f585777b9f99273105b85756eb8bbc15439e5d6af9aa98287e13a8414fe450b6acd00962c5eb0966106df4"
    ["4.0.9"]="879e1fb69114c26ab0c1f6f1445e1eb53fc0f18ac990f509d597f352eb08357ea0d646cc9e793de4986afab296317ebc8fcf33bf968cd09be10534b637b16886"
    ["4.0.8"]="92e679be5b08d2241521eb5727c69becbad13b788ecd71f7bbaabd6079d0222f9526bc1e9cf16b2cf24709b0844b69eb357b3a92d8880e98605e79685e70bdd7"
    ["4.0.7"]="bc7738b7622c7cc96fbae8621f56ebdbcc34b0583f149758746c669ccc6b9378399145400811c4671711ce2e7032d65990ba15b920c425b80580585a74d8afb3"
    ["4.0.6"]="631ed70246d3b37473c46bca214ce0b4aa5c7c9bc42a83fc4ef884edac5232b7236a52692d81233d24567ac58aa9f9a141a65bc4f5727aec11e2a2a55248991f"
    ["4.0.5"]="cc831d56800fa422cc499bed55e54b8057652e1d3564b3bdf66411f5cccc4bdae137c45e178bcbcf098b42d73f0f36849e3321b64f3e48990fa197e0a9dca7ee"
    ["4.0.4"]="7c38074d82453bc12494f52f3ac4841e2d8b1925455c52c22512e54a8f1f687b0de15163632e4210d53d8e6b7610fe6cf44317071c67d7be0c14b02e5aee155d"
    ["4.0.3"]="ca6a1fd10a9c89f606f9eeb4016912a92a2b847e81441184cf858bf6ad7a2b141368fd2a8a1bff11f18e91a1c57f9a94d586449c9ef0ff4fab9fa6937a2a992b"
    ["4.0.2"]="5b2f603212be8a7a9af68a26e942760e16018e72e9685c38dfaf66ddeec9f9d47583f6a6605500cf7fafe0116c26a230ec8f42e63a2b735e5808ebc0794e9e4a"
    ["4.0.1"]="45d2aa72796e14b6d4c09842a2df7446016083e586834d9a1f1bd9bc44131f8c10eb0a1e0b28752c07b532632bd82637725f3ef5fdf756756fc9e45d11b4be80"
    ["4.0.0"]="c73db44cb545849eb26b719887e9888ac9f78070edaba3596bd4e0fbe749e6193da35e250b43775ff1b32e62519cecac4b52490f4047a92463cea1665a8e88a0"
    ["3.0.48"]="c0650cb4abca6d61c45e6a74118365adb99e53bc59d7322ca6aff54e97cf77eeff938d89278db2812496ab44ff3fdc608a9ae3038c1d31b6a2f29cb11b1e069f"
    ["3.0.47"]="1536d871e99ac06f94d8eba91eae54d49ab7a050e66353a805d300b39074257bafb4192868220c50aad7b61298b2c14d6850c110a1c935703b93f4f64118d667"
    # v3.0.46 is the last release that published kubescape-ubuntu-latest.
    ["3.0.46"]="33e3eefacd3d1161e4220685a6ae63bd12410de7cdae0cfeca8dc1400c4ab2616eeaddaeabf4e269594008e24c9d5398f090dc38b0fe98c83998c775f5a23f0d"
    ["3.0.45"]="75007d5f4af00ce29eb20e658f1ee092f785a1cd951bc496bfc98e48466406ac237f73e021827a5dc4d46625aa90b28de88e9242e5e767bfcca79c742827c5a1"
    ["3.0.44"]="f1981bc4b1d30603ca2b24c2bee2e93a2e5ee86666fbdfafa1f4b44c4f63def706f0744665a6a0bfd4762eb4fe3146f795ce1a6792794d05111b553d17d936d9"
    ["3.0.43"]="11a9b351babf3a709ff2765c1933795a01075d36c3ae6a08883cd70bad0c2f0739f0ea26603ea9df6b7dbed6a6f76ce4ef4cafa220c7612caf07226569b31b46"
    ["3.0.42"]="af626e5ce3c78837ca52670bd206259da93010e6e4e476e254f07849493d1bcf5038f180c3104d9acde77877478fc1ff351a054462b3de2aa4c60d167bfcffe7"
    ["3.0.41"]="77ad2135b46367494834496996c5a605c11befcc8cb4e17cbe04fc4cf9d215d28e3676333c4f61a06c98d28a1c4742fd3f6bd159cc5d5c543dda041c514fb901"
    ["3.0.40"]="df3b9f891a3b557798ef083e0e18eb533bb36f8e1ec856e61280b75d055f52ac9555d32c34b2908ef19acc89ef50b2d4e69316bbce95261d6356242e0a216532"
    ["3.0.39"]="496edf0e7f825f5eb5d5b275fd750e139ba9c06f948532bfd803331e81f231aa8accbba392ee57954fb126a41e5236d929f64d3923d60c070879e5aeecb51861"
    ["3.0.38"]="c493f1726df427602f34b01a33439331cce7491fd544cf3881b00191e3cd201c7df97c8d3ca3bb7b77feb259d8444211e125e2919d50577a3fd562c4d38ff3f9"
    ["3.0.37"]="352fd9d4050308b8ce92d0bd123773a57fbdfbdc85cc8dd92f6d4ab9cea3c9206128a856c30faa62a0ea3d59624952546d1b226aa8aa5e4c3834e2c6c9c64330"
    ["3.0.36"]="6e348781351d86a205ee2cbb93b96506d3c42d5fbe1d0fa1df17790e4702a76d3ae8c5554e4482a786f1d1585d78770f8d821626aead47c4baeb7dfd5c1e3cfb"
    ["3.0.35"]="344f8fdde8695ab2b972e9f0381af8220d0cd4b22f1c076d4351ffb43fccb2138ab0711efebde375a63d0a6d92dcf7a3230181fa05de7c2407c2d28d8c412fe5"
    ["3.0.34"]="6cc5559d629c33db11b46607d85b3eef418fc53b98ae378c46b41442a829dc44bd2b4ba0661891b9b5ac96ea2ffa3000b31f4e36ec10c42a650726dd92c73db2"
    ["3.0.33"]="99acfab41d4cdff75c19175b9fc7bb8d156af45cd7d6b005742aa4202d1ffae77f941214eb24c01c53cc5fbd6684adaf504c60b33ea2e21b278826f37897385b"
    ["3.0.32"]="5b3b729a81f43376aba4e0ba0e119596d2e2cdb519eaaa8fd77a2c2547047c7971b1d7d74cc86342962d3099081b58aea87f2f82ee071c5d50a92eae70c12a56"
    ["3.0.31"]="97b43ed1f590f3059c4f63ca3fa1f6b9de60a9a68e1eddfb4fe1ce7efc7bdd13302be67d29dd6fd651cfb296facff4743bae3e02405e449ef3ea118dc5073057"
    ["3.0.30"]="1320105e5c1f34b0dc5c58a3984bb72b01989f300f748ef242f337e23150f6a9d592c107f97da31757950ec055507bc33a8cc4c3ef808ce6d021b58c49d0ed72"
    ["3.0.29"]="89750d8f4afb8c5ed90dd820d63b52c2e8dcc89758cf09babf36b4ed1ca044d11079d8b003ad5ecd2f859a2c4a97045f6208c4d33a8ec38f39aa10eef59e4efd"
    ["3.0.28"]="8249c29729540951d1c014afaf19902a916d73687d2c5b8b208b56b119db5bd69588dc274a35617835dc577095dbab8ac67f253c9ce0845336ce03713a56d011"
    ["3.0.27"]="bcc5ebb8b75b0c00a5a3189b9290c8a6c078e9a7c7de8119339943319bec26f1b059c1d81490e0ea35adb5d0ebfec2c06f25f49ad0a895e977ac58ae4d04b45d"
    # Version 3.0.26 was not released correctly.
    ["3.0.25"]="8fb63eb7956ac18f17af8db31077a3799a0ee63bd226e5861330cb182d730b7896eea2088aec9a6d6f9142b335e0482a9931a9b390cec8910759264f5ddb4979"
    ["3.0.24"]="0607b771049482c0a02b70a312d16e7491bdabe12f6f48c58637f3c766abcea33680c032445482dbb80381862058d87c94b985bcbcdd7d9b5676cf01a7c31b0d"
    ["3.0.23"]="5c76639c5fd8eb6734b3b45469aeda132f1cb482471bceec420915a3c709343197151c3ee2065634fe290dec34fa856073f188075ffe29aa4f2666f06f00b0fa"
    ["3.0.22"]="f590da75030dd9301b35c14386858d42b94909cd4732888597223968888f57090efb1b8d17ca3599ff071ae249dc1f1fb34b866d11a97e72e3df4ada732a3148"
    ["3.0.21"]="8e10a333a08de396c17fc9ce36d406b2a98c8052a6cb5f4a74e9884e87acd0c8e55655678026d6088ca7f6a98d0edab663fe50b2ba63859d1cc0757611eeca33"
    ["3.0.20"]="cdb5e2b07c791939733e35841c3f60191b591a94967a7127d5f5c1c8aa38218863b6e0fb43b9a440cc6a65b55f5107acc36a22cb2e69032466c4fdd62e040d7d"
    ["3.0.19"]="07c0fd0478835fd4a983c1c02aa1cfe7096129e1c46e24926aa9294d3bb5277b82fe1065fd72fc1f5f995801c872106386b6e4e574284f8284f2293f7be8f0d0"
    ["3.0.18"]="877b42d2ff957b96d61306fcabba9ea2609a14ed88cc44feb02900b00e38bcaa82de1cbb342f5ea858009c9b958da08afa503946e76bf681511a8cae8d65ff12"
    ["3.0.17"]="cb1f45dfd445a56acbc10ce2dd25d156c98c576c6d626215773f9905de8b4d63de870833b313fafbfadb9e8a5d774059ee2cc964847f147b4f8d75272d443fed"
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
    ASSET_NAME=$(kubescape_linux_amd64_asset "${VERSION}")
    DOWNLOAD_URL="https://github.com/kubescape/kubescape/releases/download/v${VERSION}/${ASSET_NAME}"
    echo "Downloading ${DOWNLOAD_URL}..."
    if command -v wget &> /dev/null; then
        wget "${DOWNLOAD_URL}" -O kubescape
    elif command -v curl &> /dev/null; then
        curl -L "${DOWNLOAD_URL}" -o kubescape
    else
        echo "ERROR: Neither wget nor curl is available. Please install one of them."
        exit 1
    fi
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
