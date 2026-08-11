#!/bin/bash

set -euo pipefail

archive_path="${SRCROOT}/Vendor/mitmproxy-12.2.3-macos-arm64.zip"
archive_sha256="ba1688f6827aa05ad4169845823f8f7d5b3c7ff9b4fc5724bf2f2d3ee0629a72"
helpers_path="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
runtime_path="${helpers_path}/mitmproxy.app"
executable_path="${runtime_path}/Contents/MacOS/mitmdump"

if [[ ! -f "${archive_path}" ]]; then
    echo "error: Bundled mitmproxy archive is missing at ${archive_path}"
    exit 1
fi

actual_sha256="$(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
if [[ "${actual_sha256}" != "${archive_sha256}" ]]; then
    echo "error: Bundled mitmproxy archive failed its SHA-256 integrity check"
    exit 1
fi

/bin/rm -rf "${runtime_path}"
/bin/mkdir -p "${helpers_path}"
/usr/bin/ditto -x -k "${archive_path}" "${helpers_path}"

if [[ ! -x "${executable_path}" ]]; then
    echo "error: Bundled mitmdump is missing or not executable after extraction"
    exit 1
fi

runtime_architecture="$(/usr/bin/xcrun lipo -archs "${executable_path}")"
if [[ "${runtime_architecture}" != "arm64" ]]; then
    echo "error: Bundled mitmproxy runtime must be arm64"
    exit 1
fi

version_output="$("${executable_path}" --version)"
if [[ "${version_output}" != Mitmproxy:\ 12.2.3* ]]; then
    echo "error: Lens requires bundled mitmproxy 12.2.3"
    echo "${version_output}"
    exit 1
fi

echo "Bundled ${version_output%%$'\n'*} at ${runtime_path}"
