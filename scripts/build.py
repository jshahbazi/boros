"""Build a local native playground using the already installed model/runtime."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parent


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT.parent / '.build/boros')
    parser.add_argument('--open', action='store_true')
    args = parser.parse_args()
    app = args.output.resolve() / 'Boros.app'
    contents = app / 'Contents'
    binary = contents / 'MacOS' / 'Boros'
    binary.parent.mkdir(parents=True, exist_ok=True)
    (contents / 'Resources').mkdir(exist_ok=True)
    subprocess.run([
        '/usr/bin/swiftc', '-O', '-swift-version', '5', '-parse-as-library',
        '-target', 'arm64-apple-macos14.0', '-framework', 'AppKit', '-framework', 'Foundation', '-framework', 'Security', '-framework', 'LocalAuthentication',
        *map(str, sorted((ROOT.parent / 'Sources' / 'Boros').glob('*.swift'))),
        '-I', str(ROOT.parent / 'Sources' / 'CSQLite'), '-lsqlite3', '-o', str(binary),
    ], check=True)
    info = {
        'CFBundleName': 'Boros',
        'CFBundleDisplayName': 'Boros',
        'CFBundleIdentifier': 'dev.boros.app',
        'CFBundleExecutable': 'Boros',
        'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1',
        'CFBundleShortVersionString': '0.1.0',
        'LSMinimumSystemVersion': '14.0',
        'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication',
        'NSSupportsAutomaticTermination': False,
    }
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
    print(str(app))
    if args.open:
        subprocess.run(['/usr/bin/open', '-n', str(app)], check=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError):
        print('Playground build failed; check the compiler diagnostics and local build tools.')
        raise SystemExit(1)
