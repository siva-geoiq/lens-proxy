#!/bin/bash

set -euo pipefail

ndk_version="27.0.12077973"
android_sdk="${ANDROID_HOME:-${HOME}/Library/Android/sdk}"
ndk_path="${android_sdk}/ndk/${ndk_version}"
cmake_path="${android_sdk}/cmake/3.22.1/bin/cmake"
java_home="${JAVA_HOME:-}"
if [[ -z "${java_home}" ]] && command -v brew >/dev/null 2>&1; then
    java_home="$(brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home"
fi
if [[ ! -f "${ndk_path}/build/cmake/android.toolchain.cmake" ]]; then
    echo "error: Android NDK ${ndk_version} is required"
    exit 1
fi
if [[ ! -f "${java_home}/include/jvmti.h" ]]; then
    echo "error: JAVA_HOME must provide include/jvmti.h"
    exit 1
fi

staging_root="$(mktemp -d /tmp/lens-android-agent.XXXXXX)"
trap '/bin/rm -rf "${staging_root}"' EXIT
archive_root="${staging_root}/android-inspector"
/bin/mkdir -p "${archive_root}/arm64-v8a" "${archive_root}/x86_64"

for abi in arm64-v8a x86_64; do
    build_path="${staging_root}/build-${abi}"
    JAVA_HOME="${java_home}" "${cmake_path}" \
        -S "${SRCROOT:-$(pwd)}/AndroidInspectorAgent" \
        -B "${build_path}" \
        -DCMAKE_TOOLCHAIN_FILE="${ndk_path}/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="${abi}" \
        -DANDROID_PLATFORM=26 \
        -DANDROID_STL=c++_static \
        -DCMAKE_BUILD_TYPE=Release
    "${cmake_path}" --build "${build_path}" --config Release -j 4
    /bin/cp "${build_path}/liblens_jvmti.so" "${archive_root}/${abi}/liblens_jvmti.so"
done

archive_path="${SRCROOT:-$(pwd)}/Vendor/lens-android-inspector-1.zip"
/bin/mkdir -p "$(dirname "${archive_path}")"
/bin/rm -f "${archive_path}"
(
    cd "${staging_root}"
    /usr/bin/zip -X -q -r "${archive_path}" android-inspector
)
/usr/bin/shasum -a 256 "${archive_path}"
