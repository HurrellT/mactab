#!/usr/bin/env python3
"""Exercise the shipped installer only in disposable directories; never launch it."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, expected=0):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode != expected:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


with tempfile.TemporaryDirectory(prefix="mactab installer test ") as temporary:
    directory = Path(temporary)
    source = directory / "download" / "MacTab.app"
    destination = directory / "applications" / "MacTab.app"
    sentinel = directory / "other download.txt"
    sentinel.write_text("unrelated download")
    run("ditto", str(ROOT / "build/MacTab.app"), str(source))
    quarantine = "0081;00000000;MacTabInstallerTest;"
    run("xattr", "-w", "com.apple.quarantine", quarantine, str(source))
    run("xattr", "-w", "com.apple.quarantine", quarantine, str(sentinel))
    installer = ("zsh", str(ROOT / "scripts/install.sh"), "--app", str(source),
                 "--destination", str(destination), "--no-open")

    # Default installation must retain the download's Gatekeeper quarantine.
    run(*installer)
    run("codesign", "--verify", "--strict", str(destination))
    assert run("xattr", "-p", "com.apple.quarantine", str(destination)).stdout.strip() == quarantine

    # Opt-in affects just the newly installed app, and updates preserve a backup.
    run(*installer, "--allow-unnotarized")
    run("xattr", "-p", "com.apple.quarantine", str(destination), expected=1)
    assert run("xattr", "-p", "com.apple.quarantine", str(source)).stdout.strip() == quarantine
    assert run("xattr", "-p", "com.apple.quarantine", str(sentinel)).stdout.strip() == quarantine
    assert len(list((destination.parent / ".MacTab-backups").glob("*.zip"))) == 1

    # A failed signing attempt cannot change the already installed app.
    executable = destination / "Contents/MacOS/MacTab"
    previous = executable.read_bytes()
    result = subprocess.run((*installer, "--identity", "MacTab Missing Test Identity"), capture_output=True)
    assert result.returncode != 0
    assert executable.read_bytes() == previous
    assert not list(destination.parent.glob(".mactab-install.*"))

    # Unrelated bundles and symlink destinations are rejected without replacement.
    unrelated = directory / "unrelated.app"
    run("ditto", str(source), str(unrelated))
    run("plutil", "-replace", "CFBundleIdentifier", "-string", "org.example.unrelated",
        str(unrelated / "Contents/Info.plist"))
    run("zsh", str(ROOT / "scripts/install.sh"), "--app", str(unrelated),
        "--destination", str(destination), "--no-open", expected=1)
    assert executable.read_bytes() == previous
    linked_destination = directory / "linked" / "MacTab.app"
    linked_destination.parent.mkdir()
    linked_destination.symlink_to(destination)
    run("zsh", str(ROOT / "scripts/install.sh"), "--app", str(source),
        "--destination", str(linked_destination), "--no-open", expected=1)
    assert linked_destination.is_symlink()
    assert executable.read_bytes() == previous

    run("zsh", str(ROOT / "scripts/install.sh"), "--app", str(source), "--destination",
        str(source / "Contents/Resources/MacTab.app"), "--no-open", expected=1)

    # A configured certificate must preserve the designated requirement when
    # signed content changes, which is the identity TCC uses for privacy grants.
    identity_file = ROOT / ".signing-identity"
    if identity_file.exists() and identity_file.read_text().strip() != "-":
        identity = identity_file.read_text().strip()
        signed = directory / "certificate-signed.app"
        run("ditto", str(source), str(signed))
        run("codesign", "--force", "--sign", identity, "--identifier", "com.tlh.mactab", str(signed))
        before_signature = run("codesign", "-d", "-r-", "--verbose=4", str(signed))
        run("plutil", "-replace", "CFBundleVersion", "-string", "999", str(signed / "Contents/Info.plist"))
        run("codesign", "--force", "--sign", identity, "--identifier", "com.tlh.mactab", str(signed))
        after_signature = run("codesign", "-d", "-r-", "--verbose=4", str(signed))

        def signature_line(result, prefix):
            return next(line for line in (result.stdout + result.stderr).splitlines() if line.startswith(prefix))

        assert signature_line(before_signature, "designated =>") == signature_line(after_signature, "designated =>")
        assert signature_line(before_signature, "CDHash=") != signature_line(after_signature, "CDHash=")
        run("codesign", "--verify", "--strict", str(signed))
        print("Stable certificate identity confirmed across changed signed content.")

print("Installer checks passed: quarantine scope, updates/backups, failed-signing rollback, unrelated bundles, symlinks, nested destinations, and paths with spaces.")
