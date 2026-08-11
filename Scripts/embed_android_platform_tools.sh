#!/bin/bash

set -euo pipefail

archive_path="${SRCROOT}/Vendor/platform-tools-37.0.1-darwin.zip"
archive_sha256="ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d"
helpers_path="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
runtime_path="${helpers_path}/platform-tools"
adb_path="${runtime_path}/adb"
notices_path="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AndroidPlatformTools"

if [[ ! -f "${archive_path}" ]]; then
    echo "error: Bundled Android platform-tools archive is missing at ${archive_path}"
    exit 1
fi

actual_sha256="$(/usr/bin/shasum -a 256 "${archive_path}" | /usr/bin/awk '{print $1}')"
if [[ "${actual_sha256}" != "${archive_sha256}" ]]; then
    echo "error: Bundled Android platform-tools archive failed its SHA-256 integrity check"
    exit 1
fi

/bin/rm -rf "${runtime_path}"
/bin/mkdir -p "${helpers_path}"
/usr/bin/unzip -oq "${archive_path}" \
    platform-tools/adb \
    platform-tools/NOTICE.txt \
    platform-tools/source.properties \
    -d "${helpers_path}"
/bin/chmod 755 "${adb_path}"
/bin/rm -rf "${notices_path}"
/bin/mkdir -p "${notices_path}"
/bin/mv "${runtime_path}/NOTICE.txt" "${notices_path}/NOTICE.txt"
/bin/mv "${runtime_path}/source.properties" "${notices_path}/source.properties"

if ! /usr/bin/xcrun lipo "${adb_path}" -verify_arch arm64; then
    echo "error: Bundled ADB does not support arm64"
    exit 1
fi

version_output="$("${adb_path}" version)"
if [[ "${version_output}" != *"Version 37.0.1-"* ]]; then
    echo "error: Lens requires bundled Android platform-tools 37.0.1"
    echo "${version_output}"
    exit 1
fi

/usr/bin/codesign --verify --strict "${adb_path}"
echo "Bundled Android platform-tools 37.0.1 at ${runtime_path}"
