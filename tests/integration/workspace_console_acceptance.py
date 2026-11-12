#!/usr/bin/env python3
"""Owned-fixture acceptance for public workspace listing and enter console.
Run without any other metal-sandboxd under this UID. Never mutate user instances.
"""
import argparse
import json
import os
import pty
import select
import signal
import subprocess
import time
from pathlib import Path
from native_management_acceptance import Harness, require


def check_enter_ctrl_c(binary, state, instance, host_pid):
    """Use an operator-side PTY to send real Ctrl-C, not a direct cancel RPC."""
    pid, fd = pty.fork()
    if pid == 0:
        cli = str(binary / 'sandboxctl')
        os.execv(cli, [cli, '--state-dir', str(state), 'sandbox', 'enter', instance])
    transcript = bytearray()
    prompt = (instance[:12] + ':.> ').encode()
    def until_prompt():
        received = bytearray(); deadline = time.monotonic() + 10
        while prompt not in received:
            require(time.monotonic() < deadline, 'enter prompt timed out: ' + received.decode(errors='replace'))
            if select.select([fd], [], [], .1)[0]:
                block = os.read(fd, 65536)
                require(block, 'enter exited unexpectedly')
                received.extend(block); transcript.extend(block)
        return bytes(received)
    try:
        until_prompt()
        for attempt in range(2):
            os.write(fd, b'sleep 200\n')
            for _ in range(100):
                processes = subprocess.check_output(['ps', '-axo', 'ppid=,comm='], text=True)
                if any(line.split(None, 1) == [str(host_pid), '/bin/sleep'] for line in processes.splitlines()): break
                time.sleep(.02)
            else: raise AssertionError('sleep 200 did not actually start')
            os.write(fd, b'\x03')
            cancelled = until_prompt()
            require(b'command cancelled' in cancelled and b'node quarantined' not in cancelled, 'Ctrl-C cancelled only the command')
            marker = f'after_ctrl_c_{attempt}'.encode()
            os.write(fd, b'echo ' + marker + b'\n')
            require(b'\r\n' + marker + b'\r\n' in until_prompt(), 'same enter session executes next command')
        os.write(fd, b'exit\n')
        for _ in range(100):
            child, status = os.waitpid(pid, os.WNOHANG)
            if child:
                pid = None; require(os.waitstatus_to_exitcode(status) == 0, 'enter exits normally'); break
            time.sleep(.02)
        else: raise AssertionError('enter did not exit')
        return bytes(transcript)
    finally:
        os.close(fd)
        if pid is not None:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
            os.waitpid(pid, 0)


def run(h):
    owned = []
    try:
        status = h.start()
        require(status.get('directoryListingImplemented'), 'directory capability')
        require(h.cli('list', '-h').stdout == b'No sandboxes.\n', 'readable empty list')
        records = json.loads(h.cli('create', '--count', '2').stdout)['instances']
        owned = [r['id'] for r in records]
        a, b = owned
        readable = h.cli('list', '-h').stdout
        require(readable == h.cli('list', '--human').stdout, 'human flag alias')
        require(all(iid.encode() in readable for iid in owned) and b'2 sandboxes.' in readable, 'readable full IDs and count')
        require(all(label in readable for label in (b'STATE', b'NETWORK', b'POLICY', b'CREATED (LOCAL)')), 'readable columns')
        require({r['id'] for r in json.loads(h.cli('list').stdout)['instances']} == set(owned), 'default list remains JSON')
        require(h.cli('list', '--unknown', success=False).returncode != 0, 'invalid list flag rejected')
        h.check('list -h/--human: empty/table/full IDs/count; default JSON unchanged')
        h.write(a, 'src/中文 file.txt', b'hello tree\n')
        h.write(a, '.hidden', b'hidden\n')
        h.execute(a, ['/bin/sh', '-c', 'set -eu; mkdir empty pages ./--after; printf "\\000\\001" > binary; mkfifo fifo; ln -s src link; mkfile -n 5m large; i=0; while [ "$i" -lt 260 ]; do printf "" > "pages/$(printf "%04d" "$i")"; i=$((i+1)); done'])
        page = json.loads(h.cli('ls', a).stdout)['directory']
        entries = {x['name']: x for x in page['entries']}
        require(set(entries) == {'.hidden', 'src', 'empty', 'pages', 'binary', 'fifo', 'link', 'large', '--after'}, 'all fixture metadata')
        require(entries['link']['kind'] == 'symlink' and entries['fifo']['kind'] == 'other', 'do not follow or block on special files')
        require(entries['large']['size'] == 5 * 1024 * 1024, 'large-file metadata without content read')
        require(json.loads(h.cli('ls', a, '--', '--after').stdout)['directory']['entries'] == [], 'literal option-like directory')
        require(json.loads(h.cli('ls', a, 'empty').stdout)['directory']['entries'] == [], 'empty directory')
        require(json.loads(h.cli('ls', a, 'src').stdout)['directory']['entries'][0]['path'] == 'src/中文 file.txt', 'nested Unicode path')
        require(json.loads(h.cli('ls', b).stdout)['directory']['entries'] == [], 'isolated workspace')
        h.check('public ls: metadata, nested/hidden/empty/large/binary/link/FIFO and workspace isolation')
        first = json.loads(h.cli('ls', a, 'pages').stdout)['directory']
        second = json.loads(h.cli('ls', a, 'pages', '--after', first['nextAfter']).stdout)['directory']
        require(len(first['entries']) == 256 and len(second['entries']) == 4 and not second.get('nextAfter'), 'pagination')
        require([e['name'] for e in first['entries'] + second['entries']] == [f'{i:04d}' for i in range(260)], 'complete stable listing')
        for path in ['..', '/tmp', 'src/../pages', 'link']:
            require(h.cli('ls', a, path, success=False).returncode != 0, 'reject traversal and directory link')
        h.check('directory pagination and path/link rejection')
        read = h.call('grant', instanceID=a, operations=['read'])['handle']
        write = h.call('grant', instanceID=a, operations=['write'])['handle']
        h.call('ls', auth=False, handle=read, instanceID=a, path='.')
        h.reject('ls', auth=False, handle=write, instanceID=a, path='.')
        h.reject('ls', auth=False, handle=read, instanceID=b, path='.')
        h.check('existing read capability only; write-only and foreign instance rejected')
        job = h.submit(a, ['/bin/sleep', '30'], timeout=40)
        try:
            deadline = time.monotonic() + 10
            while h.call('execution', executionID=job)['execution']['state'] == 'queued':
                require(time.monotonic() < deadline, 'live-read execution started')
                time.sleep(0.05)
            require(h.call('execution', executionID=job)['execution']['state'] == 'running', 'execution stays active')
            require(json.loads(h.cli('ls', a, 'src').stdout)['directory']['entries'][0]['path'] == 'src/中文 file.txt', 'CLI tree during execution')
            require(h.cli('read', a, 'src/中文 file.txt').stdout == b'hello tree\n', 'CLI file download during execution')
            h.call('ls', auth=False, handle=read, instanceID=a, path='.')
            h.reject('write', instanceID=a, file={'path': 'blocked', 'data': '', 'executable': False})
            h.reject('export', instanceID=a)
            h.reject('ls', auth=False, handle=write, instanceID=a, path='.')
            require(h.call('execution', executionID=job)['execution']['state'] == 'running', 'browsing did not stop execution')
        finally:
            h.call('cancel', executionID=job)
            require(h.wait(job)['state'] == 'cancelled', 'cancel remains functional after live reads')
        require(not h.call('status')['status'].get('recoveryReason'), 'live reads and clean cancellation do not quarantine')
        h.check('active execution: CLI tree/read, scoped read authorization, mutation/export rejection, clean cancellation')
        result = h.cli('enter', a, input=b':help\npwd\nmkdir console_dir\ncd console_dir\nprintf "console works\\n" > result.txt\ncat result.txt\ncd ..\nfalse\necho recovered\nexit\n')
        require(b'Simple commands' in result.stdout and b'console works' in result.stdout and b'recovered' in result.stdout, 'enter help/cwd/errors/output')
        require(h.read(a, 'console_dir/result.txt') == b'console works\n', 'enter output uses sandbox cwd')
        require(h.call('inspect', instanceID=a)['instance']['state'] == 'active', 'exit leaves sandbox active')
        require(h.read(a, 'src/中文 file.txt') == b'hello tree\n', 'listing must not mutate contents')
        h.check('real enter: help, cwd, shell operators, error recovery, output and exit leaves instance running')
        def configured(line, **settings):
            return ':run ' + json.dumps(dict(line=line, timeout=120, **settings))
        lines = [configured('cd console_dir'), configured('pwd'), configured('printf "configured\\n" > options.txt'),
                 configured('pwd', cwd='.'), configured('pwd'), configured('echo override', cwd='missing'),
                 configured('echo after_error'), ':run {"line":"touch must_not_run","timeout":0}',
                 configured('touch must_not_run', cwd='../escape'), ':run not-json', configured('exit')]
        result = h.cli('enter', a, input=('\n'.join(lines) + '\n').encode())
        require(h.read(a, 'console_dir/options.txt') == b'configured\n', 'configured commands preserve session cwd')
        require(result.stdout.count(b'/console_dir\n') >= 3 and b'after_error' in result.stdout, 'cwd override does not replace session cwd; console recovers')
        require(b'override' not in result.stdout and result.stderr, 'invalid settings/directory fail without executing candidate')
        require(h.cli('read', a, 'console_dir/must_not_run', success=False).returncode != 0, 'invalid envelope must not execute')
        require(h.cli('exec', a, '--cwd', 'missing', '--', '/bin/echo', 'must_not_execute', success=False).returncode != 0, 'plain exec rejects missing cwd')
        require(h.call('status')['status'].get('recoveryReason') is None, 'missing cwd must not quarantine the node')
        require(b'after_missing_cd' in h.cli('enter', a, input=b'cd missing\necho after_missing_cd\nexit\n').stdout, 'ordinary cd error also recovers')
        h.check('configured enter: timeout, one-command cwd, persistent cd, invalid envelope rejection and recovery')
        host_pid = h.call('inspect', instanceID=a)['instance']['physical']['pid']
        transcript = check_enter_ctrl_c(h.binary, h.state, a, host_pid)
        (h.output / 'enter_ctrl_c.txt').write_bytes(transcript)
        require(not h.call('status')['status'].get('recoveryReason'), 'Ctrl-C leaves node healthy')
        require(h.call('inspect', instanceID=a)['instance']['physical']['pid'] == host_pid, 'Ctrl-C reuses same Host')
        require(h.execute(b, ['echo', 'peer_after_ctrl_c']) == b'peer_after_ctrl_c\n', 'other sandbox remains usable')
        h.check('real terminal Ctrl-C twice: sleep 200 stops, same enter session and peer execute new commands')
        # Remove only our large-file/FIFO fixtures before the stop snapshot.
        h.execute(a, ['/bin/rm', 'large', 'fifo'])
        for iid in owned:
            h.call('stop', instanceID=iid)
            h.reject('ls', instanceID=iid, path='.')
            h.call('delete', instanceID=iid, confirmed=True)
        owned = []
        h.check('stopped instances reject listing; only owned fixtures removed')
        h.report['result'] = 'passed'
    except Exception as error:
        h.report['result'] = 'failed'; h.report['error'] = repr(error)
        raise
    finally:
        if h.process and h.process.poll() is None:
            h.call('shutdown'); h.process.wait(timeout=30)
        h.report['activeLeaseRemains'] = (h.coord / 'active-lease.json').exists()
        (h.output / 'report.json').write_text(json.dumps(h.report, indent=2) + '\n')
        for log in h.logs: log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.getuid() == 0: raise SystemExit('do not run as root')
    run(Harness(args.bin_dir, args.output))
