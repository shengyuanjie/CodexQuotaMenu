#!/usr/bin/env python3
"""Install a local build, preserving the old app and verifying background launch."""
import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def run(*args):
    subprocess.run(args, check=True, timeout=60)


def install(source):
    destination = Path('/Applications/Codex用量.app')
    executable = Path('Contents/MacOS/CodexQuotaMenu')
    if source == destination or source.is_symlink() or destination.is_symlink():
        raise RuntimeError('Source and destination must be distinct regular app directories')
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.local.codexquotamenu':
        raise RuntimeError('Not a CodexQuotaMenu app')
    run('codesign', '--verify', '--deep', '--strict', str(source))
    # Fail before replacing anything if this build lacks the launch-check entry point.
    run(str(source / executable), '--activation-launch-probe')
    plans = sorted((Path.home() / 'Library/LaunchAgents').glob('com.local.codexquotamenu.activation.*.plist'))
    originals = {p: p.read_bytes() for p in plans}
    timestamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    backup = source.parent / f'Codex用量-before-install-{timestamp}.app'
    if backup.exists():
        raise RuntimeError('Backup already exists')
    stage = Path(tempfile.mkdtemp(prefix='.CodexQuotaMenu-install-', dir=destination.parent))
    staged_app = stage / destination.name
    old_moved = False
    new_installed = False
    processes = []
    try:
        run('ditto', str(source), str(staged_app))
        run('codesign', '--verify', '--deep', '--strict', str(staged_app))
        for raw in subprocess.run(['pgrep', '-x', 'CodexQuotaMenu'], capture_output=True, text=True).stdout.split():
            command = subprocess.run(['ps', '-p', raw, '-o', 'command='], capture_output=True, text=True).stdout.strip()
            installed_exe = str(destination / executable)
            if command == installed_exe or command.startswith(installed_exe + ' '):
                if '--activate' in command or '--send-scheduled-message' in command:
                    raise RuntimeError('A scheduled job is running; retry after it completes')
                processes.append(int(raw))
        for pid in processes:
            os.kill(pid, signal.SIGTERM)
            for _ in range(50):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('Previous app did not exit; installation stopped')
        if destination.exists():
            shutil.move(str(destination), str(backup))
            old_moved = True
        os.rename(staged_app, destination)
        new_installed = True
        run('codesign', '--verify', '--deep', '--strict', str(destination))
        if hashlib.sha256((source / executable).read_bytes()).digest() != hashlib.sha256((destination / executable).read_bytes()).digest():
            raise RuntimeError('Installed executable differs from the build')
        run(str(destination / executable), '--repair-activation-registration')
        if any(p.read_bytes() != data for p, data in originals.items()):
            raise RuntimeError('Installed activation settings changed during verification')
        run(str(destination / executable), '--check')
    except Exception:
        # Restore the previous application; leave the failed build available for diagnosis.
        if new_installed:
            os.rename(destination, staged_app)
        if old_moved:
            shutil.move(str(backup), str(destination))
            domain = f'gui/{os.getuid()}'
            for p, data in originals.items():
                value = plistlib.loads(data)
                if value.get('ProgramArguments', [None])[0] != str(destination / executable):
                    continue
                label = value['Label']
                if subprocess.run(['launchctl', 'print', f'{domain}/{label}'], capture_output=True).returncode == 0:
                    run('launchctl', 'bootout', f'{domain}/{label}')
                run('launchctl', 'bootstrap', domain, str(p))
            run('open', str(destination))
        elif processes and destination.exists():
            run('open', str(destination))
        raise
    finally:
        shutil.rmtree(stage)
    run('open', str(destination))
    print(f'Installed {info["CFBundleShortVersionString"]} / Build {info["CFBundleVersion"]}; background launch verified')
    if old_moved:
        print(f'Previous app: {backup}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 scripts/install-local-app.py /path/to/Codex用量.app')
    install(Path(sys.argv[1]).resolve())
