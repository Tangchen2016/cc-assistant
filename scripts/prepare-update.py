#!/usr/bin/env python3
"""Prepare a versioned DMG and signed Sparkle feed after build-desktop.py."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
desktop = root / 'outputs/desktop'
info = plistlib.loads((desktop / 'cc助手.app/Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
assert all(c in '0123456789.' for c in version)
updates = root / 'outputs/updates'
updates.mkdir(parents=True, exist_ok=True)
source = desktop / 'cc助手-macOS.dmg'
target = updates / f'cc-assistant-{version}.dmg'
if target.exists() and hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
    raise SystemExit('Release already exists with different contents; increment both version and build number.')
shutil.copy2(source, target)
subprocess.run([
    str(root / 'work/swift-arm64/artifacts/sparkle/Sparkle/bin/generate_appcast'),
    '--account', 'cc-assistant-updates', '--download-url-prefix',
    'https://node.tangchen02.top/updates/', '--maximum-deltas', '0', str(updates),
], check=True)
print(target)
