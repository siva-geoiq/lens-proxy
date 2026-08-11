#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${LENS_RELEASE_VERSION:-1.0}"
work_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lens-release.XXXXXX")"
derived_data_path="${work_directory}/DerivedData"
distribution_directory="${project_root}/dist"
distribution_zip="${distribution_directory}/Lens-${version}-macos-arm64.zip"
checksum_file="${distribution_zip}.sha256"

cleanup() {
    /bin/rm -rf "${work_directory}"
}

trap cleanup EXIT

/usr/bin/xcodebuild \
    -quiet \
    -project "${project_root}/Lens.xcodeproj" \
    -scheme Lens \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "${derived_data_path}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

application_path="${derived_data_path}/Build/Products/Release/Lens.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${application_path}"

/bin/mkdir -p "${distribution_directory}"
/bin/rm -f "${distribution_zip}" "${checksum_file}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${application_path}" "${distribution_zip}"

checksum="$(/usr/bin/shasum -a 256 "${distribution_zip}" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "${checksum}" "$(/usr/bin/basename "${distribution_zip}")" > "${checksum_file}"
/bin/cp "${project_root}/Distribution/INSTALL.md" "${distribution_directory}/INSTALL.md"

echo "Created ${distribution_zip}"
echo "Created ${checksum_file}"
