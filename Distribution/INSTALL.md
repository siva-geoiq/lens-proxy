# Installing Lens

Lens is an ad-hoc-signed Apple-silicon application. It is not notarized by Apple.

## Disk image (recommended)

1. Download the `Lens-<version>-macos-arm64.dmg` file and its `.sha256` file.
2. Put both files in the same folder and run:
   `shasum -a 256 -c Lens-<version>-macos-arm64.dmg.sha256`
3. Open the disk image.
4. Double-click `Install Lens.command` and confirm the installation. It verifies the bundled app, copies it to Applications, and removes quarantine only from the installed Lens app.

The installer command is also unnotarized, so Gatekeeper may block it. If that happens, click **Done** (not **Move to Bin**) and run the following commands, replacing `1.1.1` with the downloaded version when necessary:

```bash
cp -R "/Volumes/Lens 1.1.1/Lens.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Lens.app
open /Applications/Lens.app
```

This removes quarantine only from the installed Lens application. Do not disable Gatekeeper globally.

You can alternatively drag `Lens.app` to the Applications shortcut and approve its first launch in System Settings > Privacy & Security.

## ZIP archive

Verify the ZIP using its matching `.sha256` file, extract it, and move `Lens.app` to Applications. The same one-time Gatekeeper approval is required.

Only override macOS security when the checksum matches an artifact downloaded from the official Lens repository.
