# GitHub releases and in-app updates

The release workflow tests FastShot, builds one universal macOS 14+ app for Apple Silicon and Intel, and publishes a ZIP, SHA-256 checksums, and a signed Sparkle appcast to GitHub Releases. Settings → About, the app menu, and the menu bar provide **Check for Updates…**. Sparkle checks periodically and prompts before installing and relaunching.

## One-time repository setup

1. Publish this repository publicly on GitHub. The About links currently use `sayeedjoy/fastshot`; the workflow automatically uses the repository it runs in for update URLs.
2. Download [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) and extract the distribution. In its directory run:

   ```sh
   ./bin/generate_keys
   ./bin/generate_keys -x /tmp/fastshot-sparkle-private-key
   ```

3. In GitHub **Settings → Secrets and variables → Actions**, create:
   - **Variable** `SPARKLE_PUBLIC_KEY`: the public key printed by `generate_keys`.
   - **Secret** `SPARKLE_PRIVATE_KEY`: the contents of the exported private key file. Keep it private and back it up securely, then delete the temporary export.

   With GitHub CLI, from the repository root:

   ```sh
   gh variable set SPARKLE_PUBLIC_KEY --body 'YOUR_PUBLIC_KEY'
   gh secret set SPARKLE_PRIVATE_KEY < /tmp/fastshot-sparkle-private-key
   rm /tmp/fastshot-sparkle-private-key
   ```

Keep the same signing key for future releases. Changing it breaks updates for installed copies. No Apple account or custom GitHub token is needed for this ad hoc signed release workflow. Organization policies must allow Actions to write repository contents for the publish job.

## Publish a version

Commit and push the application, workflow, project, and resources first, then push a stable version tag:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Use increasing three-part versions such as `v1.0.1` and `v1.1.0`. Both the displayed version and Sparkle comparison version come from the tag. Pre-release tags are deliberately rejected so beta builds cannot enter the stable update feed. **Actions → Build and release macOS app → Run workflow** builds a downloadable Actions artifact without publishing a release.

Users download the ZIP from **Releases**, extract it, move `FastShot.app` to Applications, and launch it there. After installing the first release with Sparkle, subsequent releases are offered inside FastShot. Older copies without Sparkle must be upgraded manually once. The feed is hosted at:

```text
https://github.com/OWNER/REPO/releases/latest/download/appcast.xml
```

Publish every stable app release through this workflow; a manually created latest release without `appcast.xml` breaks this feed. The workflow publishes only after the archive and signed feed are ready. Release creation intentionally fails if the release already exists, preserving existing assets. For failed runs, rerun failed jobs before creating the next tag.

## Signing and first launch

Sparkle verifies update archives with Ed25519 signatures before installing them. This is separate from Apple Developer ID signing and notarization. The current workflow uses ad hoc app signing, so macOS may block the initial downloaded app: use **System Settings → Privacy & Security → Open Anyway** only for a release you trust. Approve Screen & System Audio Recording when using capture. Apple Developer ID signing and notarization can be added later for a smoother first launch.

Library validation is disabled via `FastShot.entitlements` so the ad hoc app can load Sparkle's separately signed framework. The local install script preserves this entitlement when re-signing. Local builds without a public key keep update controls disabled; for an update-enabled local build pass `SPARKLE_PUBLIC_KEY=...` to `xcodebuild`. SwiftPM remains a dependency-free test harness and does not start Sparkle.

## Validation

Run `swift test` and the workflow's universal `xcodebuild` command. Verify the archive using `codesign --verify --deep --strict` and `lipo APP_EXECUTABLE -archs`. The workflow validates the feed version, archive size, and signature structure before publishing. Sparkle verifies the archive signature during installation.

Before distributing widely, install one tagged release in Applications, publish a higher version with the same key, and use **Check for Updates…** to verify download, installation, relaunch, version change, and screen-recording permissions on a separate Mac. Local builds alone cannot prove GitHub-hosted update delivery.

References: [Sparkle setup](https://sparkle-project.org/documentation/), [publishing updates](https://sparkle-project.org/documentation/publishing/), [GitHub runner toolchain](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).
