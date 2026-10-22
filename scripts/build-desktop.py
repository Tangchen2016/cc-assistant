#!/usr/bin/env python3
"""Build the native Swift client. Node/React/WebView are not shipped."""
from pathlib import Path
import hashlib, gzip, json, os, shutil, subprocess, tarfile, urllib.request
root = Path(__file__).resolve().parent.parent
os.chdir(root)
if Path("/Applications/Xcode.app/Contents/Developer").exists():
    os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
# Prefer an explicitly configured signing identity; never silently downgrade it.
signing_file = root / 'config/signing.local.json'
signing = json.loads(signing_file.read_text()) if signing_file.exists() else {}
signing_identity = os.environ.get('CODESIGN_IDENTITY') or signing.get('identity') or '-'
if signing_identity != '-':
    available = subprocess.check_output(['/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    if signing_identity not in available:
        raise RuntimeError('Configured code-signing identity is unavailable; refusing ad-hoc fallback.')
out = Path(os.environ.get('DESKTOP_OUTPUT_DIR', root / 'outputs/desktop'))
staging = root / 'work/native-app-stage/cc助手.app'
if staging.exists(): shutil.rmtree(staging)
resources = staging / 'Contents/Resources'
binaries = staging / 'Contents/MacOS'
resources.mkdir(parents=True); binaries.mkdir(parents=True)
def run(*args): subprocess.run([str(x) for x in args], check=True)
compiled = []
for architecture in ['arm64', 'x86_64']:
    scratch = root / f'work/swift-{architecture}'
    args = ['swift', 'build', '--build-system', 'native', '-c', 'release', '--triple', f'{architecture}-apple-macosx14.0', '--scratch-path', str(scratch)]
    run(*args)
    path = subprocess.check_output(args + ['--show-bin-path'], text=True).strip()
    compiled.append(Path(path) / 'SubscriptionStudio')
run('/usr/bin/lipo', '-create', *compiled, '-output', binaries / 'SubscriptionStudio')
shutil.copy2(root / 'desktop/native/Info.plist', staging / 'Contents/Info.plist')
shutil.copy2(root / 'docs/static-proxy-ai-setup.md', resources / 'static-proxy-ai-setup.md')
icons = root / 'work/native-app-stage/AppIcon.iconset'
run('/usr/bin/swift', root / 'desktop/native/MakeIcon.swift', icons)
run('/usr/bin/iconutil', '--convert', 'icns', icons, '--output', resources / 'AppIcon.icns')
runtime = json.loads((root / 'config/mihomo-runtime.json').read_text())
cache = root / 'work/desktop-runtime'; cache.mkdir(parents=True, exist_ok=True)
for architecture, asset in runtime['assets'].items():
    archive = cache / asset['name']
    if not archive.exists(): urllib.request.urlretrieve(f"https://github.com/MetaCubeX/mihomo/releases/download/v{runtime['version']}/{asset['name']}", archive)
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != asset['sha256']: raise RuntimeError('Mihomo checksum mismatch')
    binary = resources / f'mihomo-{architecture}'
    binary.write_bytes(gzip.decompress(data)); binary.chmod(0o755)
    run('/usr/bin/codesign', '--force', '--sign', signing_identity, binary)
archive = cache / f"mihomo-source-v{runtime['version']}.tar.gz"
if not archive.exists(): urllib.request.urlretrieve(f"https://github.com/MetaCubeX/mihomo/archive/refs/tags/v{runtime['version']}.tar.gz", archive)
shutil.copy2(archive, resources / archive.name)
with tarfile.open(archive) as source:
    (resources / 'Mihomo-LICENSE.txt').write_bytes(source.extractfile(f"mihomo-{runtime['version']}/LICENSE").read())
yams = root / 'work/swift-arm64/checkouts/Yams/LICENSE'
shutil.copy2(yams, resources / 'Yams-LICENSE.txt')
frameworks = staging / 'Contents/Frameworks'
frameworks.mkdir()
candidates = list((root / 'work/swift-arm64/artifacts').glob('**/Sparkle.framework'))
if len(candidates) != 1: raise RuntimeError('Expected one Sparkle framework')
shutil.copytree(candidates[0], frameworks / 'Sparkle.framework', symlinks=True)
run('/usr/bin/codesign', '--force', '--sign', signing_identity, staging)
run('/usr/bin/codesign', '--verify', '--deep', '--strict', staging)
out.mkdir(parents=True, exist_ok=True)
app = out / 'cc助手.app'
if app.exists(): shutil.rmtree(app)
shutil.copytree(staging, app, symlinks=True)
zipfile = out / 'cc助手-macOS.zip'
if zipfile.exists(): zipfile.unlink()
run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, zipfile)
print(f'Native client built: {app}\nPackage: {zipfile}')

dmg_stage = root / 'work/dmg-stage'
if dmg_stage.exists(): shutil.rmtree(dmg_stage)
dmg_stage.mkdir()
shutil.copytree(app, dmg_stage / app.name, symlinks=True)
(dmg_stage / 'Applications').symlink_to('/Applications')
(dmg_stage / '安装说明.txt').write_text('将 cc助手 拖入 Applications 安装。\n升级时先退出旧版，再选择替换；配置保存在用户资料目录中。\n安装后可在 cc助手 菜单中选择“检查更新…”。\n', encoding='utf-8')
dmg = out / 'cc助手-macOS.dmg'
if dmg.exists(): dmg.unlink()
run('/usr/bin/hdiutil', 'create', '-volname', 'cc助手 安装', '-srcfolder', dmg_stage, '-ov', '-format', 'UDZO', dmg)
run('/usr/bin/hdiutil', 'verify', dmg)
print(f'DMG: {dmg}')
