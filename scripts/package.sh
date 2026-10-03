#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source_app="$PWD/build/MacTab.app"
[[ -d "$source_app" ]] || { print -u2 "Run ./scripts/build.sh first."; exit 1; }
codesign --verify --strict "$source_app"
version="$(plutil -extract CFBundleShortVersionString raw "$source_app/Contents/Info.plist")"
[[ "$version" == [0-9]* && "$version" != *[^0-9A-Za-z.-]* ]] || { print -u2 "Invalid app version."; exit 1; }
architectures="$(lipo -archs "$source_app/Contents/MacOS/MacTab")"
case "$architectures" in
    *arm64*x86_64*|*x86_64*arm64*) architecture=universal ;;
    arm64|x86_64) architecture="$architectures" ;;
    *) print -u2 "Unsupported architectures: $architectures"; exit 1 ;;
esac
mkdir -p dist
staging_dir="$(mktemp -d "$PWD/dist/.mactab-package.XXXXXX")"
trap 'if [[ -d "$staging_dir" ]]; then rm -r "$staging_dir"; fi' EXIT
mkdir "$staging_dir/MacTab"
ditto "$source_app" "$staging_dir/MacTab/MacTab.app"
# The shared artifact needs no access to the developer's certificate or keychain.
codesign --force --sign - --identifier com.tlh.mactab "$staging_dir/MacTab/MacTab.app"
codesign --verify --strict "$staging_dir/MacTab/MacTab.app"
cp scripts/install.sh "$staging_dir/MacTab/install.sh"
cp docs/INSTALL.txt "$staging_dir/MacTab/INSTALL.txt"
archive_path="$PWD/dist/MacTab-$version-$architecture.zip"
ditto -c -k --sequesterRsrc --keepParent "$staging_dir/MacTab" "$archive_path"
(cd dist && shasum -a 256 "${archive_path:t}" > "${archive_path:t}.sha256")
print "Created $archive_path"
print "SHA-256:"
cat "$archive_path.sha256"
