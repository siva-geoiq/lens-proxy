# Lens

Lens is a native macOS network-debugging suite for Android, powered by a bundled mitmproxy engine and bundled ADB tools.

## Install the unsigned release

Lens currently uses an ad-hoc signature and is not notarized by Apple. Download the DMG and its matching SHA-256 file from the GitLab Package Registry, place both files in the same directory, and verify the download:

```bash
shasum -a 256 -c Lens-1.0-macos-arm64.dmg.sha256
```

Open the DMG. If macOS blocks `Install Lens.command`, click **Done** (not **Move to Bin**) and install the verified application from Terminal:

```bash
cp -R "/Volumes/Lens 1.0/Lens.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Lens.app
open /Applications/Lens.app
```

This removes the quarantine attribute only from the installed Lens application. Do not disable Gatekeeper globally.

The current release supports Apple-silicon Macs only.
