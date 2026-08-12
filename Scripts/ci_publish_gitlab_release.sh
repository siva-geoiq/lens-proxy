#!/bin/bash

set -euo pipefail

required_variables=(
    CI_API_V4_URL
    CI_COMMIT_TAG
    CI_JOB_TOKEN
    CI_PROJECT_ID
    CI_PROJECT_URL
)
for variable_name in "${required_variables[@]}"; do
    if [[ -z "${!variable_name:-}" ]]; then
        echo "error: ${variable_name} is required" >&2
        exit 1
    fi
done

package_name="lens"
package_version="${CI_COMMIT_TAG#v}"
if [[ ! "${package_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: release tags must use vX.Y.Z or X.Y.Z" >&2
    exit 1
fi

distribution_directory="${CI_PROJECT_DIR:-$(pwd)}/dist"
dmg_name="Lens-${package_version}-macos-arm64.dmg"
checksum_name="${dmg_name}.sha256"
package_base_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/${package_name}/${package_version}"
release_api_url="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/releases"

for filename in "${dmg_name}" "${checksum_name}" INSTALL.md; do
    file_path="${distribution_directory}/${filename}"
    if [[ ! -f "${file_path}" ]]; then
        echo "error: release artifact is missing: ${file_path}" >&2
        exit 1
    fi
done

appcast_path="${distribution_directory}/update-feed/appcast.xml"
if [[ ! -f "${appcast_path}" ]]; then
    echo "error: signed Sparkle appcast is missing: ${appcast_path}" >&2
    exit 1
fi

(
    cd "${distribution_directory}"
    /usr/bin/shasum -a 256 -c "${checksum_name}"
)

upload_file() {
    local filename="$1"
    local remote_status
    remote_status="$(
        /usr/bin/curl \
            --silent \
            --output /dev/null \
            --write-out '%{http_code}' \
            --head \
            --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
            "${package_base_url}/${filename}"
    )"
    if [[ "${remote_status}" == "200" ]]; then
        echo "Package file already exists: ${filename}"
        return
    fi
    if [[ "${remote_status}" != "404" ]]; then
        echo "error: GitLab returned HTTP ${remote_status} while checking ${filename}" >&2
        exit 1
    fi
    echo "Publishing ${filename} to GitLab Package Registry"
    /usr/bin/curl \
        --location \
        --fail-with-body \
        --retry 3 \
        --retry-all-errors \
        --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
        --upload-file "${distribution_directory}/${filename}" \
        "${package_base_url}/${filename}"
    echo
}

upload_file "${dmg_name}"
upload_file "${checksum_name}"
upload_file INSTALL.md

appcast_package_name="appcast.xml"
appcast_package_path="${distribution_directory}/${appcast_package_name}"
/bin/cp "${appcast_path}" "${appcast_package_path}"
upload_file "${appcast_package_name}"

release_description="Apple-silicon Lens ${package_version}. This build is ad-hoc signed and is not notarized by Apple. Verify the SHA-256 checksum and follow INSTALL.md before opening it."
release_status="$(
    /usr/bin/curl \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
        "${release_api_url}/${CI_COMMIT_TAG}"
)"

case "${release_status}" in
    200)
        echo "Updating GitLab Release ${CI_COMMIT_TAG}"
        release_method="PUT"
        release_url="${release_api_url}/${CI_COMMIT_TAG}"
        ;;
    404)
        echo "Creating GitLab Release ${CI_COMMIT_TAG}"
        release_method="POST"
        release_url="${release_api_url}"
        ;;
    *)
        echo "error: GitLab returned HTTP ${release_status} while checking the release" >&2
        exit 1
        ;;
esac

/usr/bin/curl \
    --request "${release_method}" \
    --location \
    --fail-with-body \
    --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
    --data-urlencode "name=Lens ${package_version}" \
    --data-urlencode "tag_name=${CI_COMMIT_TAG}" \
    --data-urlencode "description=${release_description}" \
    "${release_url}"
echo

add_release_link() {
    local name="$1"
    local package_filename="$2"
    local direct_asset_path="$3"
    local response_file
    local response_code
    response_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/lens-release-link.XXXXXX")"
    response_code="$(
        /usr/bin/curl \
            --silent \
            --show-error \
            --output "${response_file}" \
            --write-out '%{http_code}' \
            --request POST \
            --header "JOB-TOKEN: ${CI_JOB_TOKEN}" \
            --data-urlencode "name=${name}" \
            --data-urlencode "url=${package_base_url}/${package_filename}" \
            --data-urlencode "direct_asset_path=${direct_asset_path}" \
            --data-urlencode "link_type=package" \
            "${release_api_url}/${CI_COMMIT_TAG}/assets/links"
    )"
    case "${response_code}" in
        201)
            echo "Added release asset: ${name}"
            ;;
        409)
            echo "Release asset already exists: ${name}"
            ;;
        *)
            /bin/cat "${response_file}" >&2
            /bin/rm -f "${response_file}"
            return 1
            ;;
    esac
    /bin/rm -f "${response_file}"
}

add_release_link "Lens ${package_version} for macOS (Apple silicon)" "${dmg_name}" "/${dmg_name}"
add_release_link "SHA-256 checksum" "${checksum_name}" "/${checksum_name}"
add_release_link "Installation guide" INSTALL.md /INSTALL.md
add_release_link "Sparkle update feed" "${appcast_package_name}" "/${appcast_package_name}"

echo "Published Lens ${package_version}: ${CI_PROJECT_URL}/-/releases/${CI_COMMIT_TAG}"
