#!/bin/bash

set -euo pipefail

installer_directory="$(cd "$(dirname "$0")" && pwd)"
source_application="${installer_directory}/Lens.app"
destination_application="/Applications/Lens.app"
temporary_application="/Applications/.Lens.installing.$$"

fail() {
    echo
    echo "Installation failed: $1" >&2
    echo "Press Return to close this window."
    read -r
    exit 1
}

shell_quote() {
    /usr/bin/printf "'%s'" "$(/usr/bin/printf '%s' "$1" | /usr/bin/sed "s/'/'\\\\''/g")"
}

[[ -d "${source_application}" ]] || fail "Lens.app is missing from this disk image."
/usr/bin/codesign --verify --deep --strict "${source_application}" 2>/dev/null || \
    fail "Lens.app failed its code-signature integrity check."

bundle_identifier="$(/usr/bin/defaults read "${source_application}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
[[ "${bundle_identifier}" == "com.lenskart.lens.Lens" ]] || \
    fail "The application has an unexpected bundle identifier."

/usr/bin/file "${source_application}/Contents/MacOS/Lens" | /usr/bin/grep -q 'arm64' || \
    fail "This release requires an Apple-silicon Mac."

echo "Lens is ad-hoc signed and is not notarized by Apple."
echo "This installer will copy only Lens.app to /Applications and remove"
echo "the quarantine attribute only from that installed application."
echo
read -r -p "Install Lens now? [y/N] " confirmation
[[ "${confirmation}" == "y" || "${confirmation}" == "Y" ]] || exit 0

quoted_source="$(shell_quote "${source_application}")"
quoted_temporary="$(shell_quote "${temporary_application}")"
quoted_destination="$(shell_quote "${destination_application}")"

install_command="/bin/rm -rf ${quoted_temporary} && "
install_command+="/usr/bin/ditto ${quoted_source} ${quoted_temporary} && "
install_command+="/usr/bin/codesign --verify --deep --strict ${quoted_temporary} && "
install_command+="/bin/rm -rf ${quoted_destination} && "
install_command+="/bin/mv ${quoted_temporary} ${quoted_destination} && "
install_command+="/usr/bin/xattr -dr com.apple.quarantine ${quoted_destination}"

if ! /usr/bin/osascript - "${install_command}" <<'APPLESCRIPT'
on run arguments
    do shell script (item 1 of arguments) with administrator privileges
end run
APPLESCRIPT
then
    fail "macOS did not authorize the installation."
fi

echo
echo "Lens was installed successfully. Opening Lens…"
/usr/bin/open "${destination_application}"
echo "You can close this window."
