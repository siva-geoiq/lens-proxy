#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${DEVELOPER_ID_APPLICATION:-}"
team_id="${DEVELOPMENT_TEAM:-}"
notary_profile="${NOTARYTOOL_PROFILE:-}"
version="${LENS_RELEASE_VERSION:-1.0}"

if [[ -z "${identity}" || -z "${team_id}" || -z "${notary_profile}" ]]; then
    echo "error: Set DEVELOPER_ID_APPLICATION, DEVELOPMENT_TEAM, and NOTARYTOOL_PROFILE"
    exit 1
fi

work_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lens-release.XXXXXX")"
archive_path="${work_directory}/Lens.xcarchive"
submission_zip="${work_directory}/Lens-notarization.zip"
distribution_directory="${project_root}/dist"
distribution_zip="${distribution_directory}/Lens-${version}-macos-arm64.zip"

cleanup() {
    /bin/rm -rf "${work_directory}"
}

trap cleanup EXIT

/usr/bin/xcodebuild \
    -project "${project_root}/Lens.xcodeproj" \
    -scheme Lens \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -archivePath "${archive_path}" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${identity}" \
    DEVELOPMENT_TEAM="${team_id}" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    archive

application_path="${archive_path}/Products/Applications/Lens.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${application_path}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${application_path}" "${submission_zip}"
/usr/bin/xcrun notarytool submit "${submission_zip}" --keychain-profile "${notary_profile}" --wait
/usr/bin/xcrun stapler staple "${application_path}"
/usr/bin/xcrun stapler validate "${application_path}"
/usr/sbin/spctl --assess --type execute --verbose=2 "${application_path}"

/bin/mkdir -p "${distribution_directory}"
/bin/rm -f "${distribution_zip}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${application_path}" "${distribution_zip}"
/usr/bin/shasum -a 256 "${distribution_zip}"
