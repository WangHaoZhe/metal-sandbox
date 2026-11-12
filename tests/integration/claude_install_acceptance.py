#!/usr/bin/env python3
"""Opt-in official Claude downloads and isolated install/session acceptance.

Uses real Claude binaries inside App Sandbox. Model replies come from a local
synthetic Messages fixture, not a real model or host credentials. Not part of
the offline test.sh suite. Requires an idle same-UID service coordination slot.
"""
import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import threading
import uuid
from native_management_acceptance import Harness, require


class MessagesFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'NETWORK_FIXTURE_OK')

    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers.get('content-length', 0))))
        if 'count_tokens' in self.path:
            self.send_response(200); self.send_header('content-type', 'application/json'); self.end_headers()
            self.wfile.write(b'{"input_tokens":100}'); return
        messages = json.dumps(data.get('messages', []))
        self.server.messages.append(messages)
        label = 'SESSION_A' if 'SESSION_A' in messages else 'SESSION_B'
        message = {'id':'msg_install_fixture', 'type':'message', 'role':'assistant', 'model':data['model'],
                   'content':[], 'stop_reason':None, 'stop_sequence':None, 'usage':{'input_tokens':100,'output_tokens':10}}
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
        def emit(kind, **fields):
            self.wfile.write(('event: '+kind+'\ndata: '+json.dumps({'type':kind, **fields})+'\n\n').encode())
            self.wfile.flush()
        emit('message_start', message=message)
        emit('content_block_start', index=0, content_block={'type':'text','text':''})
        emit('content_block_delta', index=0, delta={'type':'text_delta','text':label+'_REPLY'})
        emit('content_block_stop', index=0)
        emit('message_delta', delta={'stop_reason':'end_turn','stop_sequence':None}, usage={'output_tokens':10})
        emit('message_stop')


def install_from_task(h, instance_id, version):
    """Use the task installer, with a version override only in the test copy."""
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), 'invalid test version')
    source = (Path(__file__).resolve().parents[2] / 'examples/tasks/metal_bloom/agent/setup.sh').read_bytes()
    marker = b'\nversion=2.1.209\n'
    require(source.count(marker) == 1, 'task installer version declaration')
    source = b"ANTHROPIC_API_KEY=''\n" + source.replace(marker, b'\nversion=' + version.encode() + b'\n', 1)
    h.write(instance_id, 'instruction.md', b'Installation-only fixture\n')
    h.write(instance_id, 'setup.sh', source)
    result = h.wait(h.submit(instance_id, ['/bin/sh', './setup.sh'], 900), timeout=950)
    stderr = base64.b64decode(result.get('result', {}).get('stderr', ''))
    require(result.get('result', {}).get('outcome', {}).get('exitCode') == 2 and b'No Agent has started.' in stderr,
            'task must install successfully, then stop before rollout without an API key')
    return result


def run(h, versions):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), MessagesFixture)
    server.messages = []
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}'
    try:
        require(h.start().get('networkClientImplemented'), 'per-instance network support')
        offline = json.loads(h.cli('create','--count','1','--no_network').stdout)['instances'][0]
        online = json.loads(h.cli('create','--count','2').stdout)['instances']
        require(not offline['networkClient'] and all(r['networkClient'] for r in online), 'network choice recorded')
        args = ['/usr/bin/curl','--fail','--silent','--show-error','--max-time','5',url]
        denied = h.wait(h.submit(offline['id'],args))
        require(denied['state'] == 'failed', 'explicitly offline sandbox must deny network')
        for record in online:
            require(h.execute(record['id'],args) == b'NETWORK_FIXTURE_OK', 'default sandbox connects')
        h.check('default permits network; --no_network instances deny it')
        missing = h.wait(h.submit(online[0]['id'], ['claude','--version']))
        require(missing['state'] == 'failed' and not h.call('status')['status'].get('recoveryReason'), 'missing local CLI is a preflight error, not quarantine')

        h.report['installations'] = []
        homes = []
        for record, version in zip(online, versions):
            iid = record['id']
            h.execute(iid, ['/bin/sh','-c','mkdir -p "$HOME/.claude"; printf \'{"env":{"KEEP_INSTALL_TEST":"yes"}}\\n\' > "$HOME/.claude/settings.json"'])
            install = install_from_task(h, iid, version)
            h.report['installations'].append(install)
            for stream in ('stdout','stderr'):
                (h.output/f'{version}_{stream}.log').write_bytes(base64.b64decode(install.get('result',{}).get(stream,'')))
            output = h.execute(iid,['claude','--version']).decode().strip()
            require(output.startswith(version+' '), output)
            data = h.execute(iid,['/bin/sh','-c','printf "%s\\n" "$HOME"; command -v claude; cat "$HOME/.claude/settings.json"']).decode().splitlines()
            home, binary = data[:2]; settings = json.loads('\n'.join(data[2:]))
            require(home.startswith(record['physical']['home']+'/'), 'private HOME stays in this container')
            require(binary == home+'/.local/bin/claude', 'private binary, not host CLI')
            require(settings == {'env': {'KEEP_INSTALL_TEST': 'yes'}}, 'task preparation preserves user settings')
            homes.append(home)
            h.check(f'official installer in private HOME: {version}; normal claude command resolves locally')
        require(homes[0] != homes[1], 'separate environment roots')
        # A's version remains pinned after B installs a different version.
        require(h.execute(online[0]['id'],['claude','--version']).decode().startswith(versions[0]+' '), 'B must not replace A')

        session_id = str(uuid.uuid4())
        for index, record in enumerate(online):
            label = 'SESSION_'+('A' if index == 0 else 'B')
            prefix = ('ANTHROPIC_API_KEY=local-install-fixture-not-a-key '
                      f'ANTHROPIC_BASE_URL={shlex.quote(url)} '
                      'DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 '
                      'CLAUDE_CONFIG_DIR="$HOME/.claude" claude --bare --model claude-sonnet-4-6 --output-format json ')
            first = h.execute(record['id'], ['/bin/sh','-c', prefix+f'--session-id {session_id} -p {label}'],120)
            require((label+'_REPLY').encode() in first, first.decode(errors='replace'))
            resumed = h.execute(record['id'], ['/bin/sh','-c', prefix+f'--resume {session_id} -p again'],120)
            require((label+'_REPLY').encode() in resumed, resumed.decode(errors='replace'))
            require(label+'_REPLY' in server.messages[-1], 'resume sends stored assistant history')
            require(('SESSION_B' if index == 0 else 'SESSION_A') not in server.messages[-1], 'no peer session data')
            h.check(label+': real CLI session saved/resumed with synthetic local Messages replies')

        # No host data is copied into either sandbox; canaries are test-owned.
        canary = h.output/'host_canary'; canary.write_text('controller-only')
        targets = [homes[1]+'/.claude/settings.json',str(canary),str(h.state/'operator_token')]
        for target in targets:
            failed = h.wait(h.submit(online[0]['id'],['/bin/cat',target]))
            require(failed['state'] == 'failed', 'network grant must not grant peer or controller file access')
        h.check('network-enabled CLI cannot read peer configuration, controller canary or operator token')
        require(not h.call('status')['status'].get('recoveryReason'), 'node remains healthy')
        for record in online: h.call('stop',instanceID=record['id'])
        restored = h.call('restore',instanceID=online[0]['id'])['instance']
        require(restored['networkClient'], 'restore retains network choice')
        require(h.execute(restored['id'],args) == b'NETWORK_FIXTURE_OK', 'restored network works')
        absent = h.wait(h.submit(restored['id'],['claude','--version']))
        require(absent['state'] == 'failed', 'workspace snapshot does not silently copy private HOME')
        h.check('restore preserves network setting, not private HOME installation/session files')
        h.delete_owned()
        h.report['result'] = 'passed'
    except Exception as error:
        h.report['result'] = 'failed'; h.report['error'] = repr(error)
        raise
    finally:
        server.shutdown(); server.server_close()
        if h.process and h.process.poll() is None:
            h.call('shutdown'); h.process.wait(timeout=30)
        (h.output/'report.json').write_text(json.dumps(h.report,indent=2)+'\n')
        for log in h.logs: log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--allow-download',action='store_true',required=True)
    parser.add_argument('--versions',nargs=2,default=['2.1.209','2.1.208'])
    args=parser.parse_args()
    if os.getuid()==0: raise SystemExit('do not run as root')
    run(Harness(args.bin_dir,args.output),args.versions)
