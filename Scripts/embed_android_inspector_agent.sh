#!/bin/bash

set -euo pipefail

archive_path="${SRCROOT}/Vendor/lens-android-inspector-1.zip"
archive_sha256="d73a77d04ecd7c172c289265fe43a55e689909d981685297093159ae1b547ab2"
helpers_path="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
agent_path="${helpers_path}/android-inspector"

if [[ ! -f "${archive_path}" ]]; then
    echo "error: Bundled Android inspector archive is missing at ${archive_path}"
    exit 1
fi
actual_sha256="$(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
if [[ "${actual_sha256}" != "${archive_sha256}" ]]; then
    echo "error: Bundled Android inspector archive failed its SHA-256 integrity check"
    exit 1
fi

/bin/rm -rf "${agent_path}"
/bin/mkdir -p "${helpers_path}"
/usr/bin/unzip -oq "${archive_path}" -d "${helpers_path}"

for abi in arm64-v8a x86_64; do
    library="${agent_path}/${abi}/liblens_jvmti.so"
    if [[ ! -f "${library}" ]]; then
        echo "error: Android inspector agent is missing for ${abi}"
        exit 1
    fi
done

echo "Bundled Lens Android inspector agent"
