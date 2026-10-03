# Stable signing for personal builds

MacTab's default ad-hoc signature changes its designated requirement when the executable changes. macOS associates privacy grants with that requirement, so an enabled entry can belong to an older build. A reusable certificate lets macOS recognize successive builds as the same app. See Apple's [explanation of designated requirements and privacy grants](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Local certificate (no Developer Program required for personal testing)

1. Open **Keychain Access**. Choose **Keychain Access → Certificate Assistant → Create a Certificate…**.
2. Name it **MacTab Local**. Choose **Self Signed Root** for Identity Type and **Code Signing** for Certificate Type.
3. Select **Let me override defaults** to choose a longer validity period (for example, 3650 days), then continue with the remaining defaults and save to the login keychain. Keep this certificate and its private key for future builds.
4. Verify the identity is available:

   ```sh
   security find-identity -v -p codesigning
   ```

   If it is not listed as valid, open the certificate in Keychain Access and check its **Trust → Code Signing** setting. For this certificate you created yourself, set that specific setting to **Always Trust**. The certificate must also have its private key attached under My Certificates.

   To diagnose the existing certificate without changing trust:

   ```sh
   ./scripts/trust-local-signing.sh --check
   ```

   If the identity is present with `CSSMERR_TP_NOT_TRUSTED`, repair the user-domain Code Signing trust and save its fingerprint for builds:

   ```sh
   ./scripts/trust-local-signing.sh
   ```

   This helper exports only the public certificate, verifies the existing identity and Code Signing policy, and asks macOS to trust that certificate for Code Signing only. It does not create or export a private key. macOS can show an authorization dialog. It saves `.signing-identity` automatically after the identity becomes valid.

5. From the project directory, save the identity name once and build:

   ```sh
   printf '%s\n' 'MacTab Local' > .signing-identity
   ./scripts/build.sh
   codesign -d -r- build/MacTab.app
   ```

   `.signing-identity` is ignored by Git. The build script reads it automatically. An explicit `MACTAB_SIGN_IDENTITY` environment variable takes precedence.

6. Quit the old MacTab process. Remove its old entries in **Privacy & Security → Accessibility** and **Screen & System Audio Recording**. Add the new `build/MacTab.app` to both and enable it, then relaunch. MacTab's **Check permissions** reports the effective grants for the running build.

After this one-time transition, continue using the same certificate, bundle identifier (`com.tlh.mactab`), and app path for subsequent builds. Changing the certificate, switching signing methods, or replacing an expired certificate can require new grants. Signing does not itself grant permission.

Apple documents this local certificate workflow in [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html). Self-signed certificates are for local signing; they do not provide Apple's verified-developer or notarization experience. Our [free prebuilt sharing workflow](SHARING.md) uses an explicit app-specific CLI installation instead.

## Apple-issued identity

If you have an Apple Development or Developer ID Application certificate and private key in your keychain, use its full name or SHA-1 fingerprint from `security find-identity -v -p codesigning`:

```sh
MACTAB_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/build.sh
```

Alternatively, put that identity on the single line of `.signing-identity` for future builds. Xcode can create an Apple Development certificate under **Settings → Accounts → Manage Certificates**. See Apple's [certificate management instructions](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html).

## Missing thumbnails

The checkbox in System Settings can show an old grant even if the current binary is denied. Accessibility controls enumeration/focus; Screen Recording controls window thumbnails. Both grants can become stale after an ad-hoc rebuild. The effective Screen Recording state is shown in MacTab Settings and **Check permissions**, and missing capture access is shown in the window-row heading. After refreshing a grant, relaunch MacTab before testing.

With valid access, some minimized, protected, or uncapturable windows can still show an icon. Capture errors are logged under subsystem `com.tlh.mactab`, category `previews`; no window contents or titles are written to the log.
