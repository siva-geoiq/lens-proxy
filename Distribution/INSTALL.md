# Installing Lens

Lens is distributed as an ad-hoc-signed Apple Silicon application. It is not notarized by Apple.

1. Download `Lens-1.0-macos-arm64.zip` and its `.sha256` file from the project release.
2. Verify the checksum with `shasum -a 256 -c Lens-1.0-macos-arm64.zip.sha256`.
3. Extract the ZIP and move `Lens.app` to Applications.
4. Try to open Lens once.
5. Open System Settings, select Privacy & Security, then choose Open Anyway for Lens.

Only override macOS security when the checksum matches an artifact from the official Lens repository release.
