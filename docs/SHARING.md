# Sharing a prebuilt app without a paid Apple developer account

Recipients download a ZIP containing `MacTab.app`, `install.sh`, and installation instructions. They do not need Xcode, an Apple developer account, or your signing certificate. Nothing is automatically uploaded by the packaging script.

## Prepare the download

For a build that runs on both Apple Silicon and Intel Macs:

```sh
./scripts/build.sh --universal
./scripts/package.sh
```

The packager creates `dist/MacTab-<version>-universal.zip` and a SHA-256 checksum file. To produce only your Mac's architecture, run `./scripts/build.sh` without `--universal` first. The archive name includes its architecture.

The packager applies an ad-hoc signature to a temporary copy. Your personal signed development bundle remains unchanged, and no certificate, private key, `.signing-identity`, preferences, or captured data is included. Publish the ZIP and checksum through your chosen release host. A checksum detects changes relative to the published value; it is not developer authentication.

## Recipient command

After downloading and extracting the ZIP, open Terminal in the extracted `MacTab` folder and run:

```sh
./install.sh --allow-unnotarized
```

The installer copies the app to `~/Applications/MacTab.app`, applies a local ad-hoc signature, and removes `com.apple.quarantine` from this app only. It then opens Settings. It needs neither Xcode nor `sudo`; it does not disable Gatekeeper globally or change privacy grants.

The flag explicitly opts into running this unnotarized download. Recipients should use the release only when they trust its source. Without the flag, quarantine is preserved and macOS may require **Privacy & Security → Open Anyway**, as described in [Apple's app-opening guidance](https://support.apple.com/en-us/102445). This route does not provide the Developer ID and notarization experience.

Recipients grant **Accessibility** and, for thumbnails, **Screen & System Audio Recording** themselves. They then relaunch MacTab and use **Check permissions**. Ad-hoc-signed updates may require removing and re-adding stale entries.

Quit the installed app before an update. The installer backs up the previous app into `~/Applications/.MacTab-backups`, preserves preferences, validates the source bundle and supported CPU architecture, and rejects an unrelated destination. Signing and validation finish in a temporary directory before replacing the installed app.

If a recipient already has a valid local signing identity, they can reuse it across downloaded releases:

```sh
./install.sh --allow-unnotarized --identity 'Their Local Certificate'
```

Run `./install.sh --help` for a different app path or destination. The command above is ready for a downloaded ZIP. A one-line download-and-install command can be added once a release URL and hosting location are known.

## Development verification

```sh
python3 scripts/test-install.py
```

This test uses disposable copies, never launches them, and checks quarantine preservation and app-only removal, backup creation, failed-signing rollback, rejection of unrelated apps and symlinks, and paths containing spaces. Python is used only for developer tests; it is not an installer dependency.
