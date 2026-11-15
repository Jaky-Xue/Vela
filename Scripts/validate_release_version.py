"""Reject an app bundle whose version disagrees with the project's build settings."""
import plistlib
import re
import sys
from pathlib import Path

project = Path("Vela.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
info = plistlib.loads(Path(sys.argv[1]).read_bytes())
for setting, key in [("MARKETING_VERSION", "CFBundleShortVersionString"),
                     ("CURRENT_PROJECT_VERSION", "CFBundleVersion")]:
    versions = set(re.findall(r"\b" + setting + r"\s*=\s*([^;]+);", project))
    versions = {version.strip().strip('"') for version in versions}
    if len(versions) != 1 or info.get(key) not in versions:
        raise SystemExit(f"Package version mismatch: {key}={info.get(key)!r}, {setting}={sorted(versions)!r}")
print(f"Verified package version {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
