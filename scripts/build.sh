#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_arguments=(-c release)
case "${1:-}" in
    --universal) build_arguments+=(--arch arm64 --arch x86_64) ;;
    --help|-h) print "Usage: ./scripts/build.sh [--universal]"; exit 0 ;;
    "") ;;
    *) print -u2 "Unknown argument: $1"; exit 1 ;;
esac
(( $# <= 1 )) || { print -u2 "Too many arguments."; exit 1; }
signing_identity="${MACTAB_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" && -f .signing-identity ]]; then
    signing_identity="$(<.signing-identity)"
fi
signing_identity="${signing_identity:--}"
swift build "${build_arguments[@]}"
binary_dir="$(swift build "${build_arguments[@]}" --show-bin-path)"
bundle_path="$PWD/build/MacTab.app"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_dir/MacTab" "$bundle_path/Contents/MacOS/MacTab"
cp Resources/Info.plist "$bundle_path/Contents/Info.plist"
# Use the same certificate and identifier for every rebuild to preserve TCC identity.
codesign --force --sign "$signing_identity" --identifier com.tlh.mactab "$bundle_path"
codesign --verify --strict "$bundle_path"
print "Built $bundle_path"
if [[ "$signing_identity" == "-" ]]; then
    print "Local ad-hoc signature: after code changes, an existing privacy grant may no longer match."
    print "If macOS shows MacTab enabled but the app reports denied, re-add this bundle in Accessibility and Screen Recording."
else
    print "Signed with $signing_identity"
fi
