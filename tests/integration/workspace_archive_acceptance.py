#!/usr/bin/env python3
"""Large-file ZIP snapshots through the actual managed CLI and restricted Host."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import time
import uuid
import zipfile
from native_management_acceptance import Harness, require


def stream_digest(file):
    value = hashlib.sha256()
    while True:
        data = file.read(1024 * 1024)
        if not data: return value.hexdigest()
        value.update(data)


def digest(path):
    with path.open('rb') as file: return stream_digest(file)


def run(binary, output):
    h = Harness(binary, output)
    large_paths = []
    try:
        h.start()
        a, b = [r['id'] for r in h.call('create', count=2)['instances']]
        source = h.output / 'source.bin'; large_paths.append(source)
        with source.open('wb') as file:
            for _ in range(128): file.write(os.urandom(1024 * 1024))
        expected = digest(source)
        h.cli('write', a, 'nested/large.bin', '--from', str(source))
        downloaded = h.output / 'download.bin'; large_paths.append(downloaded)
        h.cli('read', a, 'nested/large.bin', '--out', str(downloaded))
        require(digest(downloaded) == expected, '128 MiB upload/download hashes')
        h.check('128 MiB file transfers use bounded chunks across IPC frames')
        h.execute(a, ['/bin/sh', '-c', 'chmod +x nested/large.bin; /bin/dd if=/dev/zero of=second.bin bs=1048576 count=65 2>/dev/null; printf private > "$HOME/not_in_snapshot"; ln -s large.bin nested/alias'], 120)
        h.execute(a, ['/bin/mkdir', '-p', 'empty/nested'])
        require(h.call('inspect', instanceID=a)['instance']['checkpointBytes'] == 0, 'write/exec do not automatically snapshot')
        h.cli('snapshot', a)
        current = h.call('inspect', instanceID=a)['instance']
        require(not current.get('checkpointError') and current['checkpointBytes'] == 193 * 1024 * 1024, 'large explicit checkpoint')
        snapshot = h.output / 'snapshot.zip'; large_paths.append(snapshot)
        h.cli('export', a, '--out', str(snapshot))
        require(snapshot.stat().st_size > 16 * 1024 * 1024, 'compressed archive also exceeds IPC limit')
        with zipfile.ZipFile(snapshot) as archive:
            require(archive.testzip() is None, 'independent Python ZIP CRC validation')
            require(set(archive.namelist()) == {'nested/large.bin', 'second.bin', 'nested/alias', 'empty/nested/'}, 'workspace and empty directories only; no private HOME')
            require(archive.getinfo('nested/large.bin').external_attr >> 16 & 0o111, 'executable bit in standard ZIP')
            with archive.open('nested/large.bin') as file:
                require(stream_digest(file) == expected, 'standard ZIP content hash')
        h.check('193 MiB explicit snapshot is a standard ZIP with modes and safe symlink, excluding HOME')
        h.cli('import', b, '--from', str(snapshot))
        h.cli('read', b, 'nested/large.bin', '--out', str(downloaded))
        require(digest(downloaded) == expected, 'import hash')
        require(h.execute(b, ['/bin/sh', '-c', 'test -x nested/large.bin && test -L nested/alias && test -d empty/nested && test ! -e "$HOME/not_in_snapshot"; echo ok']) == b'ok\n', 'import modes, empty directories and private HOME independence')
        h.call('stop', instanceID=a)
        clone = json.loads(h.cli('restore', a).stdout)['instance']['id']
        h.cli('read', clone, 'nested/large.bin', '--out', str(downloaded))
        require(digest(downloaded) == expected, 'clone hash')
        started = h.call('start', instanceID=a)['instance']
        require(started['id'] == a and h.execute(a, ['/bin/cat', started['physical']['home'] + '/Library/Application Support/MetalSandbox/home/not_in_snapshot']) == b'private', 'same-ID start retains HOME')
        h.check('large ZIP import, snapshot clone and same-ID restart preserve data')
        # A conventional third-party ZIP64 local header is accepted as well.
        external = h.output / 'external.zip'
        with zipfile.ZipFile(external, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            with archive.open('external.txt', 'w', force_zip64=True) as file: file.write(b'zip64')
        h.cli('import', b, '--from', str(external))
        require(h.cli('read', b, 'external.txt').stdout == b'zip64', 'ZIP64 import')
        unsupported = h.output / 'not_archive.json'
        unsupported.write_text(json.dumps([{'path': 'unexpected.txt', 'data': base64.b64encode(b'ignored').decode(), 'executable': False}]))
        require(h.cli('import', b, '--from', str(unsupported), success=False).returncode != 0, 'non-ZIP snapshot rejected')
        require('unexpected.txt' not in [e['name'] for e in h.call('ls', instanceID=b)['directory']['entries']], 'rejected import leaves workspace unchanged')
        h.check('independently generated ZIP64 imports; non-ZIP snapshots rejected before upload')
        for bad_name in ['../outside', '/absolute', 'nested/../../outside']:
            bad = h.output / 'bad.zip'
            with zipfile.ZipFile(bad, 'w') as archive: archive.writestr(bad_name, b'bad')
            require(h.cli('import', b, '--from', str(bad), success=False).returncode != 0, 'traversal ZIP rejected')
        with snapshot.open('rb') as file: bad.write_bytes(file.read(2048))
        require(h.cli('import', b, '--from', str(bad), success=False).returncode != 0, 'truncated ZIP rejected')
        before = h.call('inspect', instanceID=b)['instance']['checkpointSHA256']
        # Drop a socket halfway through upload. Nothing may be applied.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(30); connection.connect(str(h.coord / 'native.sock'))
            def send(value):
                data = json.dumps(value).encode(); connection.sendall(struct.pack('>I', len(data)) + data)
            def receive(n):
                data = b''
                while len(data) < n:
                    part = connection.recv(n-len(data)); require(part, 'connection closed'); data += part
                return data
            send({'operation': 'upload', 'requestID': str(uuid.uuid4()), 'operatorToken': h.token, 'instanceID': b})
            length, = struct.unpack('>I', receive(4)); require(json.loads(receive(length))['ok'], 'upload authorized')
            with snapshot.open('rb') as file: chunk = file.read(256 * 1024)
            send({'data': base64.b64encode(chunk).decode()})
        time.sleep(.2)
        require(h.call('inspect', instanceID=b)['instance']['checkpointSHA256'] == before, 'interrupted upload preserves checkpoint')
        require(h.cli('read', b, 'external.txt').stdout == b'zip64', 'Host still responsive')
        handle = h.output / 'read_handle.json'
        h.cli('grant', b, '--operations', 'read', '--out', str(handle))
        require(h.cli('--handle', str(handle), 'write', b, 'forbidden', '--from', str(source), success=False).returncode != 0, 'scoped write denied')
        h.cli('--handle', str(handle), 'read', b, 'nested/large.bin', '--out', str(downloaded))
        require(digest(downloaded) == expected, 'scoped large read')
        require(not h.call('status')['status'].get('recoveryReason'), 'no quarantine after successful transfers')
        h.check('unsafe/truncated ZIPs and interrupted uploads do not replace saved data; scoped rights still enforced')
        h.report.update(result='pass', fileBytes=source.stat().st_size, snapshotBytes=193*1024*1024, sha256=expected)
        h.delete_owned()
    except Exception as error:
        h.report.update(result='fail', error=str(error)); raise
    finally:
        if h.process and h.process.poll() is None:
            h.call('shutdown'); h.process.wait(timeout=120)
        for path in large_paths: path.unlink(missing_ok=True)
        (h.output / 'report.json').write_text(json.dumps(h.report, indent=2) + '\n')
        for log in h.logs: log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); run(args.bin_dir, args.output)
