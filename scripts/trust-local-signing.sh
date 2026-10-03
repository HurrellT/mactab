#!/bin/zsh
# Repair the existing local certificate; never creates or exports a private key.
set -euo pipefail
cd "${0:A:h}/.."
check_only=false
if [[ "${1:-}" == --check ]]; then
    check_only=true
    shift
fi
certificate_name="${1:-MacTab Local}"
keychain_path="$HOME/Library/Keychains/login.keychain-db"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/mactab-signing.XXXXXX")"
certificate_path="$temporary_dir/certificate.pem"
trap 'if [[ -f "$certificate_path" ]]; then rm "$certificate_path"; fi; rmdir "$temporary_dir"' EXIT

if ! security find-certificate -c "$certificate_name" -p "$keychain_path" > "$certificate_path"; then
    print -u2 "No '$certificate_name' certificate in the login keychain. Create it with Certificate Assistant first."
    exit 1
fi
fingerprint="$(/usr/bin/openssl x509 -in "$certificate_path" -outform DER | shasum -a 1 | awk '{print toupper($1)}')"
matching="$(security find-identity -p codesigning "$keychain_path")"
if [[ "$matching" != *"$fingerprint"* ]]; then
    print -u2 "The certificate has no matching Code Signing identity. Check that its private key is attached and its type is Code Signing."
    exit 1
fi
valid="$(security find-identity -v -p codesigning "$keychain_path")"
if [[ "$valid" != *"$fingerprint"* ]]; then
    print "Identity found but not valid:"
    print -r -- "$matching" | awk -v hash="$fingerprint" 'index($0, hash)'
    if $check_only; then exit 1; fi
    # Only a self-signed local certificate is accepted by this repair helper.
    subject_line="$(/usr/bin/openssl x509 -in "$certificate_path" -noout -subject)"
    issuer_line="$(/usr/bin/openssl x509 -in "$certificate_path" -noout -issuer)"
    if [[ "${subject_line#subject=}" != "${issuer_line#issuer=}" ]]; then
        print -u2 "This helper only trusts a self-issued local certificate."
        exit 1
    fi
    security verify-cert -c "$certificate_path" -r "$certificate_path" -p codeSign -L -l -q
    print "Trusting '$certificate_name' for Code Signing only in your user trust store."
    print "macOS may ask you to authorize this change."
    security add-trusted-cert -r trustRoot -p codeSign -k "$keychain_path" "$certificate_path"
    valid="$(security find-identity -v -p codesigning "$keychain_path")"
    if [[ "$valid" != *"$fingerprint"* ]]; then
        print -u2 "The identity is still invalid. Check certificate dates and Code Signing trust in Keychain Access."
        exit 1
    fi
fi
print "Valid Code Signing identity: $certificate_name ($fingerprint)"
if ! $check_only; then
    print -r -- "$fingerprint" > .signing-identity
    print "Saved .signing-identity. Future builds reuse this certificate."
fi
