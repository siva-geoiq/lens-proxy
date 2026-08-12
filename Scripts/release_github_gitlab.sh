#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${LENS_RELEASE_VERSION:-1.0}"
build_number="${LENS_BUILD_NUMBER:-1}"
update_feed_url="${LENS_UPDATE_FEED_URL:-}"
update_download_base_url="${LENS_UPDATE_DOWNLOAD_BASE_URL:-}"
update_release_page_url="${LENS_UPDATE_RELEASE_PAGE_URL:-}"
work_directory="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/lens-release.XXXXXX")"
derived_data_path="${work_directory}/DerivedData"
distribution_directory="${project_root}/dist"
distribution_zip="${distribution_directory}/Lens-${version}-macos-arm64.zip"
zip_checksum_file="${distribution_zip}.sha256"
distribution_dmg="${distribution_directory}/Lens-${version}-macos-arm64.dmg"
dmg_checksum_file="${distribution_dmg}.sha256"
dmg_staging_directory="${work_directory}/DMG"

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
    MARKETING_VERSION="${version}" \
    CURRENT_PROJECT_VERSION="${build_number}" \
    LENS_UPDATE_FEED_URL="${update_feed_url}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

application_path="${derived_data_path}/Build/Products/Release/Lens.app"
/usr/bin/codesign --force --deep --sign - --timestamp=none "${application_path}"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${application_path}"

/bin/mkdir -p "${distribution_directory}"
/bin/rm -f \
    "${distribution_zip}" \
    "${zip_checksum_file}" \
    "${distribution_dmg}" \
    "${dmg_checksum_file}"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${application_path}" "${distribution_zip}"

zip_checksum="$(/usr/bin/shasum -a 256 "${distribution_zip}" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "${zip_checksum}" "$(/usr/bin/basename "${distribution_zip}")" > "${zip_checksum_file}"

/bin/mkdir -p "${dmg_staging_directory}"
/usr/bin/ditto "${application_path}" "${dmg_staging_directory}/Lens.app"
/bin/ln -s /Applications "${dmg_staging_directory}/Applications"
/bin/cp "${project_root}/Distribution/Install Lens.command" "${dmg_staging_directory}/Install Lens.command"
/bin/chmod 755 "${dmg_staging_directory}/Install Lens.command"
/bin/cp "${project_root}/Distribution/INSTALL.md" "${dmg_staging_directory}/INSTALL.md"

/usr/bin/hdiutil create \
    -quiet \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname "Lens ${version}" \
    -srcfolder "${dmg_staging_directory}" \
    "${distribution_dmg}"

dmg_checksum="$(/usr/bin/shasum -a 256 "${distribution_dmg}" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "${dmg_checksum}" "$(/usr/bin/basename "${distribution_dmg}")" > "${dmg_checksum_file}"
/bin/cp "${project_root}/Distribution/INSTALL.md" "${distribution_directory}/INSTALL.md"

if [[ -n "${LENS_SPARKLE_PRIVATE_KEY:-}" ]]; then
    if [[ -z "${update_feed_url}" || -z "${update_download_base_url}" ]]; then
        echo "error: LENS_UPDATE_FEED_URL and LENS_UPDATE_DOWNLOAD_BASE_URL are required when signing an update feed" >&2
        exit 1
    fi
    if [[ ! -f "${LENS_SPARKLE_PRIVATE_KEY}" ]]; then
        echo "error: LENS_SPARKLE_PRIVATE_KEY must point to the GitLab CI file variable" >&2
        exit 1
    fi

    sparkle_generate_appcast="${derived_data_path}/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
    if [[ ! -x "${sparkle_generate_appcast}" ]]; then
        echo "error: Sparkle generate_appcast was not resolved at ${sparkle_generate_appcast}" >&2
        exit 1
    fi

    update_feed_directory="${distribution_directory}/update-feed"
    /bin/rm -rf "${update_feed_directory}"
    /bin/mkdir -p "${update_feed_directory}"
    /bin/cp "${distribution_dmg}" "${update_feed_directory}/$(/usr/bin/basename "${distribution_dmg}")"
    /bin/cp "${project_root}/Distribution/UPDATE_INDEX.html" "${update_feed_directory}/index.html"

    appcast_arguments=(
        --ed-key-file "${LENS_SPARKLE_PRIVATE_KEY}"
        --download-url-prefix "${update_download_base_url%/}/"
        --maximum-versions 1
        --maximum-deltas 0
        -o "${update_feed_directory}/appcast.xml"
    )
    if [[ -n "${update_release_page_url}" ]]; then
        appcast_arguments+=(--link "${update_release_page_url}")
    fi
    "${sparkle_generate_appcast}" "${appcast_arguments[@]}" "${update_feed_directory}"
    echo "Created ${update_feed_directory}/appcast.xml"
fi

echo "Created ${distribution_zip}"
echo "Created ${zip_checksum_file}"
echo "Created ${distribution_dmg}"
echo "Created ${dmg_checksum_file}"
