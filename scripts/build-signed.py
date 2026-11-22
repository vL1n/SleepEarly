#!/usr/bin/env python3
"""Manual, credentialed archive/export using an ephemeral macOS keychain."""
import base64
import hashlib
import os
import plistlib
import secrets
import shutil
import subprocess
import tempfile
from pathlib import Path

os.chdir(Path(__file__).resolve().parents[1])
os.umask(0o077)
bundle = os.environ.get("FRAMEFLOW_BUNDLE_ID") or "com.frameflow.app"
method = os.environ.get("EXPORT_METHOD", "debugging")
if method not in {"debugging", "release-testing"}:
    raise SystemExit("Choose debugging or release-testing.")
required = ["IOS_P12_BASE64", "IOS_P12_PASSWORD", "IOS_PROFILE_BASE64"]
if not all(os.environ.get(key) for key in required):
    print("Signed build skipped: signing credentials are incomplete.")
    raise SystemExit(0)

def run(*args, capture=False):
    # Avoid printing command arguments, which can contain the keychain password.
    result = subprocess.run(args, stdout=subprocess.PIPE if capture else None)
    if result.returncode:
        raise SystemExit(f"{args[0]} failed ({result.returncode})")
    return result.stdout

with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    p12 = temp / "identity.p12"
    profile = temp / "profile.mobileprovision"
    p12.write_bytes(base64.b64decode(os.environ.pop("IOS_P12_BASE64")))
    profile.write_bytes(base64.b64decode(os.environ.pop("IOS_PROFILE_BASE64")))
    password = os.environ.pop("IOS_P12_PASSWORD")
    meta = plistlib.loads(run("security", "cms", "-D", "-i", profile, capture=True))
    team = meta["TeamIdentifier"][0]
    import uuid
    profile_id = str(uuid.UUID(meta["UUID"])).upper()
    profiles = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
    profiles.mkdir(parents=True, exist_ok=True)
    installed = profiles / (profile_id + ".mobileprovision")
    previous = installed.read_bytes() if installed.exists() else None
    keychain = temp / "ci.keychain-db"
    key = secrets.token_hex(24)
    old = [s.strip().strip('"') for s in run("security", "list-keychains", "-d", "user", capture=True).decode().splitlines()]
    run("security", "create-keychain", "-p", key, keychain)
    try:
        run("security", "set-keychain-settings", "-lut", "21600", keychain)
        run("security", "unlock-keychain", "-p", key, keychain)
        run("security", "import", p12, "-P", password, "-k", keychain, "-T", "/usr/bin/codesign")
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", key, keychain)
        run("security", "list-keychains", "-d", "user", "-s", keychain, *old)
        identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain, capture=True).decode()
        fingerprints = (hashlib.sha1(c).hexdigest().upper() for c in meta["DeveloperCertificates"])
        identity = next((f for f in fingerprints if f in identities), None)
        if not identity:
            raise SystemExit("No valid signing identity matching the profile.")
        shutil.copyfile(profile, installed)
        archive = temp / "FrameFlow.xcarchive"
        run("xcodebuild", "archive", "-project", "FrameFlow.xcodeproj", "-scheme", "FrameFlow",
            "-configuration", "Release", "-destination", "generic/platform=iOS", "-sdk", "iphoneos",
            "-archivePath", archive, "ARCHS=arm64", "CODE_SIGN_STYLE=Manual", "FRAMEFLOW_BUNDLE_ID=" + bundle,
            "DEVELOPMENT_TEAM=" + team, "CODE_SIGN_IDENTITY=" + identity, "PROVISIONING_PROFILE_SPECIFIER=" + profile_id)
        options = temp / "ExportOptions.plist"
        options.write_bytes(plistlib.dumps(dict(method=method, teamID=team, signingStyle="manual",
            signingCertificate=identity, provisioningProfiles={bundle: profile_id}, destination="export")))
        target = temp / "export"
        run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportOptionsPlist", options, "-exportPath", target)
        ipa, = target.glob("*.ipa")
        run("unzip", "-tq", ipa)
        unpacked = temp / "verify"
        run("ditto", "-x", "-k", ipa, unpacked)
        app = unpacked / "Payload/FrameFlow.app"
        run("codesign", "--verify", "--deep", "--strict", app)
        if not (app / "embedded.mobileprovision").is_file():
            raise SystemExit("Signed export is missing its profile.")
        dest = Path("build/signed/FrameFlow-signed.ipa")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ipa, dest)
    finally:
        if previous is None:
            installed.unlink(missing_ok=True)
        else:
            installed.write_bytes(previous)
        try:
            run("security", "list-keychains", "-d", "user", "-s", *old)
        finally:
            run("security", "delete-keychain", keychain)
