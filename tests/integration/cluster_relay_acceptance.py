import argparse
import base64
import json
import os
from pathlib import Path
import struct
import subprocess
import time
import uuid
import zipfile


def send(stream, value):
    data = json.dumps(value).encode()
    stream.write(struct.pack('>I', len(data)) + data)
    stream.flush()


def read_exact(stream, length):
    data = bytearray()
    while len(data) < length:
        block = stream.read(length - len(data))
        if not block:
            raise RuntimeError('relay disconnected')
        data.extend(block)
    return bytes(data)


def receive(stream):
    length = struct.unpack('>I', read_exact(stream, 4))[0]
    assert 0 < length <= 16 * 1024 * 1024
    return json.loads(read_exact(stream, length))


def run(bin_dir, output):
    output.mkdir(parents=True, exist_ok=False)
    temporary = output / 'temporary'
    temporary.mkdir()
    environment = dict(os.environ, METAL_SANDBOX_COORDINATION_DIR=str(output / 'coordination'), TMPDIR=str(temporary) + '/')
    cli = bin_dir / 'sandboxctl'
    state = output / 'state'
    with (output / 'service.log').open('wb') as log:
        service = subprocess.Popen([str(bin_dir / 'metal-sandboxd'), '--allow-trusted-code', '--bin-dir', str(bin_dir), '--state-dir', str(state)], env=environment, stdout=log, stderr=log)
        relay = None
        instances = []
        try:
            for _ in range(100):
                if service.poll() is not None:
                    raise RuntimeError('test service exited')
                ready = subprocess.run([str(cli), '--state-dir', str(state), 'sandbox', 'status'], env=environment, capture_output=True)
                if ready.returncode == 0:
                    break
                time.sleep(0.1)
            else:
                raise RuntimeError('test service did not start')
            relay = subprocess.Popen([str(cli), '--state-dir', str(state), 'cluster-relay'], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            def request(operation, **kwargs):
                value = dict(operation=operation, requestID=str(uuid.uuid4()), **kwargs)
                send(relay.stdin, value)
                reply = receive(relay.stdout)
                assert reply['requestID'] == value['requestID'], reply
                return reply

            created = request('create', count=1)
            assert created['ok'], created
            instance = created['instances'][0]['id']
            instances.append(instance)
            assert request('status')['status']['clusterImplemented']

            source = output / 'input.zip'
            with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr('data.txt', 'relay-data\n')
            assert request('upload', instanceID=instance)['ok']
            send(relay.stdin, {'data': base64.b64encode(source.read_bytes()).decode()})
            send(relay.stdin, {})
            assert receive(relay.stdout)['ok']

            reply = request('download', instanceID=instance)
            assert reply['ok'], reply
            downloaded = bytearray()
            while True:
                block = receive(relay.stdout)
                if 'data' not in block:
                    assert 'error' not in block, block
                    break
                downloaded.extend(base64.b64decode(block['data']))
            destination = output / 'download.zip'
            destination.write_bytes(downloaded)
            with zipfile.ZipFile(destination) as archive:
                assert archive.read('data.txt') == b'relay-data\n'

            handle = request('grant', instanceID=instance, operations=['read'])['handle']
            assert request('read', instanceID=instance, handle=handle, path='data.txt')['ok']
            denied = request('write', instanceID=instance, handle=handle,
                             file=dict(path='forbidden.txt', data=base64.b64encode(b'no').decode(), executable=False))
            assert not denied['ok'], denied

            command = dict(argv=['/bin/cat', 'data.txt'], cwd='.', timeoutSeconds=5, maxLogBytes=1024)
            submitted = request('exec', instanceID=instance, command=command)
            assert submitted['ok'], submitted
            execution = submitted['execution']['id']
            for _ in range(100):
                current = request('execution', executionID=execution)['execution']
                if current['state'] in ['succeeded', 'failed', 'cancelled', 'interrupted']:
                    break
                time.sleep(0.05)
            assert current['state'] == 'succeeded', current
            assert base64.b64decode(current['result']['stdout']) == b'relay-data\n'

            relay.stdin.close()
            relay.wait(timeout=10)
            assert relay.returncode == 0, relay.stderr.read().decode()
            relay = subprocess.Popen([str(cli), '--state-dir', str(state), 'cluster-relay'], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            assert request('execution', executionID=execution)['execution']['state'] == 'succeeded'
            assert request('stop', instanceID=instance)['ok']
            assert request('delete', instanceID=instance, confirmed=True)['ok']
            instances.clear()
            assert request('list')['instances'] == []
            (output / 'report.json').write_text(json.dumps(dict(result='passed', coverage=['real public CLI relay', 'framed requests', 'streamed upload/download', 'scoped authorization', 'real App Sandbox execution', 'reconnect result query']), indent=2))
        finally:
            if relay:
                if relay.stdin and not relay.stdin.closed:
                    relay.stdin.close()
                relay.wait(timeout=10)
            for instance in instances:
                for args in [['stop', instance], ['delete', instance, '--confirm']]:
                    subprocess.run([str(cli), '--state-dir', str(state), 'sandbox'] + args, env=environment, capture_output=True)
            if service.poll() is None:
                subprocess.run([str(cli), '--state-dir', str(state), 'sandbox', 'shutdown'], env=environment, check=True, capture_output=True)
                service.wait(timeout=20)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    run(arguments.bin_dir.resolve(), arguments.output.resolve())
