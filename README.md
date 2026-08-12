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

## Automated GitLab releases

Push a semantic-version tag to build and publish a DMG automatically:

```bash
git tag v1.1.0
git push origin v1.1.0
```

The tag pipeline builds an Apple-silicon Release app, publishes the DMG, checksum, installation guide, and signed Sparkle appcast to the Generic Package Registry, creates a GitLab Release containing permanent asset links, and deploys the public update feed through GitLab Pages. Authentication for publishing uses GitLab's automatically provided `CI_JOB_TOKEN`; no personal access token is embedded in Lens.

Installed release builds check the appcast when Lens starts. When a newer version is available, Lens shows a non-blocking banner with **Later** and **Install Update** actions. **Lens → Check for Updates…** performs a manual check using Sparkle's standard installer. Every update archive is verified using the Ed25519 public key embedded in the app before it is installed.

The repository can remain private, but the project's Pages access must be public so installed apps can fetch `appcast.xml` and the DMG without storing GitLab credentials. The protected, masked file variable `LENS_SPARKLE_PRIVATE_KEY` signs archives in CI and is available only to the protected `v*` tag pattern. Do not print, download, or commit this private key.

The Xcode job requires an Apple-silicon GitLab shell runner with Xcode installed and the runner tag `macos-arm64`. The project currently has only Linux runners, so register a macOS runner before pushing the first release tag.
