# Lens

Lens is a native macOS network-debugging suite for Android, powered by a bundled mitmproxy engine and bundled ADB tools.

## Install the unsigned release

Lens currently uses an ad-hoc signature and is not notarized by Apple. Download the DMG and its matching SHA-256 file from the [GitHub Releases page](https://github.com/siva-geoiq/lens-proxy/releases/latest), place both files in the same directory, and verify the download:

```bash
shasum -a 256 -c Lens-1.1.1-macos-arm64.dmg.sha256
```

Open the DMG. If macOS blocks `Install Lens.command`, click **Done** (not **Move to Bin**) and install the verified application from Terminal, replacing `1.1.1` with the downloaded version when necessary:

```bash
cp -R "/Volumes/Lens 1.1.1/Lens.app" /Applications/
xattr -dr com.apple.quarantine /Applications/Lens.app
open /Applications/Lens.app
```

This removes the quarantine attribute only from the installed Lens application. Do not disable Gatekeeper globally.

The current release supports Apple-silicon Macs only.

## Automated GitHub releases

Push a semantic-version tag to build and publish a DMG automatically:

```bash
git tag v1.1.2
git push origin v1.1.2
```

The tag workflow runs on GitHub's Apple-silicon `macos-26` runner. It builds Lens, publishes the DMG, checksum, installation guide, and signed Sparkle appcast to a GitHub Release in this repository, and marks that release as latest. The stable update feed is:

```text
https://github.com/siva-geoiq/lens-proxy/releases/latest/download/appcast.xml
```

Installed release builds check the appcast when Lens starts. When a newer version is available, Lens shows a non-blocking banner with **Later** and **Install Update** actions. **Lens → Check for Updates…** performs a manual check using Sparkle's standard installer. Every update archive is verified using the Ed25519 public key embedded in the app before it is installed.

The Actions secret `LENS_SPARKLE_PRIVATE_KEY` signs release archives. Keep it private: do not print, download, or commit it. Existing Lens installations trust the corresponding Ed25519 public key embedded in the app, so rotating this key requires an explicit migration release.

The workflow also supports manual dispatch for an existing `vX.Y.Z` tag. It refuses malformed tags and tags whose commits are not contained in `main`.
