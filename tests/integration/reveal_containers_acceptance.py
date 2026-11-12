#!/usr/bin/env python3
"""Read-only CLI checks using an existing container identity; never opens Finder.

Path and symlink edge cases use temporary roots in sandbox-selftest instead of
creating test entries in the macOS-managed Containers directory.
"""
import argparse
import json
from pathlib import Path
import subprocess
import uuid


def run(cli, identifier):
    def invoke(*args, success=True):
        result = subprocess.run([str(cli), 'sandbox', 'reveal-containers', *args], capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == success, result.stderr + result.stdout
        return json.loads(result.stdout) if success else result.stderr
    missing = 'local.metal-sandbox.instance-' + str(uuid.uuid4())
    preview = invoke(identifier, missing, identifier, '--preview')
    assert preview['paths'] == [str(Path.home() / 'Library/Containers' / identifier)]
    assert preview['missing'] == [missing] and preview['finderRequested'] is False
    assert invoke(missing)['finderRequested'] is False
    for args in [[], ['../outside'], ['file:///tmp'], ['sbx-' + str(uuid.uuid4())], [identifier, '../outside']]:
        invoke(*args, '--preview', success=False)
    print('PASS read-only CLI preview, exact paths, deduplication, missing targets and invalid-input rejection')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--bundle-id', required=True)
    args = parser.parse_args()
    run(args.bin_dir.resolve() / 'sandboxctl', args.bundle_id)
