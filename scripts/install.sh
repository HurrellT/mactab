#!/bin/zsh
# Included beside MacTab.app in the free prebuilt download. No Xcode or sudo.
set -euo pipefail
source_app="${0:A:h}/MacTab.app"
destination="$HOME/Applications/MacTab.app"
signing_identity="-"
allow_unnotarized=false
launch_app=true

usage() {
    cat <<'EOF'
Usage: ./install.sh [--allow-unnotarized] [--identity NAME_OR_SHA1]
                    [--app PATH] [--destination PATH] [--no-open]

Installs MacTab.app to ~/Applications, using a local ad-hoc signature by default.
--allow-unnotarized removes download quarantine from this app only, allowing
this unnotarized release to run. Use it only for a download you trust.
Without this flag, macOS may require Privacy & Security → Open Anyway.
--identity uses your existing signing certificate to keep identity across updates.
Updates back up the previous app to .MacTab-backups beside the installed app.
EOF
}
fail() { print -u2 -- "$*"; exit 1; }
while (( $# )); do
    case "$1" in
        --allow-unnotarized) allow_unnotarized=true; shift ;;
        --no-open) launch_app=false; shift ;;
        --app|--destination|--identity)
            (( $# >= 2 )) || fail "Missing value for $1"
            case "$1" in
                --app) source_app="$2" ;;
                --destination) destination="$2" ;;
                --identity) signing_identity="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage; fail "Unknown argument: $1" ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || fail "MacTab requires macOS."
os_version="$(sw_vers -productVersion)"
(( ${os_version%%.*} >= 14 )) || fail "MacTab requires macOS 14 or later."
[[ ! -L "$source_app" && ! -L "$destination" ]] || fail "Source or destination is a symbolic link; use an app directory."
source_app="${source_app:A}"
destination="${destination:A}"
[[ -d "$source_app" && ! -L "$source_app" ]] || fail "Missing MacTab.app: $source_app"
[[ "$destination" == */MacTab.app ]] || fail "Destination must end in /MacTab.app."
[[ "$source_app" != "$destination" ]] || fail "Source and destination must be different."
[[ "$source_app" != "$destination"/* && "$destination" != "$source_app"/* ]] || fail "Source and destination cannot contain one another."
[[ ! -L "$destination" ]] || fail "Destination is a symbolic link; choose another location."
[[ ! -e "$destination" || -d "$destination" ]] || fail "Destination is not an app directory."
bundle_id="$(plutil -extract CFBundleIdentifier raw "$source_app/Contents/Info.plist")"
[[ "$bundle_id" == com.tlh.mactab ]] || fail "The source bundle is not MacTab."
if [[ -e "$destination" ]]; then
    existing_id="$(plutil -extract CFBundleIdentifier raw "$destination/Contents/Info.plist")"
    [[ "$existing_id" == com.tlh.mactab ]] || fail "Refusing to replace an unrelated app."
fi
running_paths="$(ps -axo comm=)"
for running_path in "${(@f)running_paths}"; do
    [[ "$running_path" != "$destination/Contents/MacOS/MacTab" ]] || fail "Quit the installed MacTab before updating it."
done
binary="$source_app/Contents/MacOS/MacTab"
[[ -f "$binary" && -x "$binary" && ! -L "$binary" ]] || fail "Missing MacTab executable."
architecture="$(uname -m)"
if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then architecture=arm64; fi
description="$(/usr/bin/file -b "$binary")"
[[ "$description" == *"$architecture"* ]] || fail "This build does not support $architecture. Download the matching or universal build."
codesign --verify --strict "$source_app"

destination_parent="${destination:h}"
mkdir -p "$destination_parent"
staging_dir="$(mktemp -d "$destination_parent/.mactab-install.XXXXXX")"
cleanup() {
    if [[ -d "$staging_dir/previous.app" && ! -e "$destination" ]]; then
        mv "$staging_dir/previous.app" "$destination"
    fi
    if [[ -d "$staging_dir" ]]; then rm -r "$staging_dir"; fi
}
trap cleanup EXIT
staged_app="$staging_dir/MacTab.app"
ditto "$source_app" "$staged_app"
codesign --force --sign "$signing_identity" --identifier com.tlh.mactab "$staged_app"
codesign --verify --strict "$staged_app"
if $allow_unnotarized; then
    xattr -dr com.apple.quarantine "$staged_app"
else
    # ditto/codesign can adjust quarantine flags. Preserve the source's explicit
    # quarantine when the recipient has not opted into clearing it.
    quarantine_value="$(xattr -p com.apple.quarantine "$source_app" 2>/dev/null || true)"
    if [[ -n "$quarantine_value" ]]; then
        xattr -w com.apple.quarantine "$quarantine_value" "$staged_app"
    fi
fi
if [[ -d "$destination" ]]; then
    backup_dir="$destination_parent/.MacTab-backups"
    mkdir -p "$backup_dir"
    backup_path="$backup_dir/MacTab-$(date +%Y%m%d-%H%M%S)-$RANDOM.zip"
    ditto -c -k --sequesterRsrc --keepParent "$destination" "$backup_path"
    print "Previous app backed up to $backup_path"
    mv "$destination" "$staging_dir/previous.app"
fi
mv "$staged_app" "$destination"
print "Installed $destination"
if [[ "$signing_identity" == - ]]; then
    print "Locally ad-hoc signed. New releases may require refreshing privacy permissions."
else
    print "Signed with your identity: $signing_identity"
fi
print "Enable MacTab in Accessibility and, for previews, Screen & System Audio Recording."
if $launch_app; then open "$destination" --args --settings; fi
