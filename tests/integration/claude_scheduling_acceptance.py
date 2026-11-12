#!/usr/bin/env python3
"""Native Claude Bash scheduling acceptance. Uses dummy auth and only owned fixtures.
Needs network for the official installer; never executes host-installed Claude.
"""
import base64,http.server,json,os,subprocess,sys,threading,time
from pathlib import Path
from native_management_acceptance import Harness,require
from task_scheduling_acceptance import STAMP,MAKE
from claude_install_acceptance import install_from_task
import argparse
parser=argparse.ArgumentParser(description="Real sandbox-installed Claude 2.1.209 with deterministic local model responses; not a model capability score.")
parser.add_argument('--bin-dir',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
require(os.getuid()!=0,'do not run as root')
h=Harness(args.bin_dir,args.output)
R=Path(__file__).resolve().parents[2]
plans={}
seen={}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def do_POST(self):
        data=json.loads(self.rfile.read(int(self.headers.get('content-length',0))))
        if 'count_tokens' in self.path:
            body=b'{"input_tokens":100}';self.send_response(200);self.send_header('content-type','application/json');self.end_headers();self.wfile.write(body);return
        name=self.path.split('/')[1]; plan=plans[name]
        results=[c for m in data.get('messages',[]) if isinstance(m.get('content'),list) for c in m['content'] if c.get('type')=='tool_result']
        seen[name]=results
        completed={c['tool_use_id'] for c in results}
        index=next((i for i in range(len(plan)) if f'tool_{name}_{i}' not in completed),len(plan))
        blocks=([{'type':'text','text':'Fixture complete.'}] if index==len(plan) else [{'type':'tool_use','id':f'tool_{name}_{index}','name':'Bash','input':{'command':plan[index],'description':'Execute ordinary fixture command','timeout':1000 if name=='tool_timeout' else 20000}}])
        message={'id':f'msg_{name}_{index}','type':'message','role':'assistant','model':data.get('model'),'content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':100,'output_tokens':20}}
        self.send_response(200);self.send_header('content-type','text/event-stream');self.end_headers()
        def emit(name,v): self.wfile.write(('event: '+name+'\ndata: '+json.dumps(v)+'\n\n').encode());self.wfile.flush()
        emit('message_start',{'type':'message_start','message':message})
        for i,b in enumerate(blocks):
            initial=b|({'text':''} if b['type']=='text' else {'input':{}})
            emit('content_block_start',{'type':'content_block_start','index':i,'content_block':initial})
            delta={'type':'text_delta','text':b['text']} if b['type']=='text' else {'type':'input_json_delta','partial_json':json.dumps(b['input'])}
            emit('content_block_delta',{'type':'content_block_delta','index':i,'delta':delta})
            emit('content_block_stop',{'type':'content_block_stop','index':i})
        emit('message_delta',{'type':'message_delta','delta':{'stop_reason':'end_turn' if index==len(plan) else 'tool_use','stop_sequence':None},'usage':{'output_tokens':20}})
        emit('message_stop',{'type':'message_stop'})
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
def launch(iid,name,plan):
    plans[name]=plan
    script=f'''#!/bin/sh
set -eu
export ANTHROPIC_API_KEY=local-fixture-not-a-real-key
export ANTHROPIC_BASE_URL=http://127.0.0.1:{server.server_port}/{name}
export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
export CLAUDE_CODE_TMPDIR="$TMPDIR/claude"
export CLAUDE_CODE_SHELL=/bin/bash
export METAL_SANDBOX_HARNESS=claude
export PATH="${{METAL_SANDBOX_SHELL_HELPER%/*}}:$PATH"
export CLAUDE_CODE_SHELL_PREFIX=sandbox-shell
"$HOME/.local/bin/claude" --setting-sources '' --settings "$METAL_SANDBOX_CLAUDE_SETTINGS" --dangerously-skip-permissions --tools Bash --no-chrome --strict-mcp-config --mcp-config '{{"mcpServers":{{}}}}' -p 'Execute fixture commands.' --model claude-opus-4-8 --output-format stream-json --verbose --no-session-persistence --max-turns 15
'''
    h.write(iid,f'{name}.sh',script.encode())
    return h.call('exec',instanceID=iid,command={'argv':['/bin/sh',f'./{name}.sh'],'cwd':'.','timeoutSeconds':150,'maxLogBytes':4194304,'agentSession':True})['execution']['id']
try:
    h.start()
    a=h.call('create',count=1,networkClient=True)['instances'][0]['id']
    b=h.call('create',count=1,networkClient=True,taskPolicy={'serial':[{'executable':'/bin/sh'}]})['instances'][0]['id']
    for iid in (a,b):
        install_from_task(h, iid, '2.1.209')
        require(b'2.1.209' in h.execute(iid,['claude','--version']),'private official installation')
    h.check('two independently script-installed Claude 2.1.209 binaries inside App Sandbox')
    for iid in (a,b):
        h.write(iid,'stamp.c',STAMP);h.write(iid,'Makefile',MAKE)
        h.write(iid,'metal_queue.mm',(R/'examples/metal_queue.mm').read_bytes())
        h.execute(iid,['clang++','-O2','-fobjc-arc','-framework','Foundation','-framework','Metal','metal_queue.mm','-o','metal_queue'])
    jobs=[launch(iid,name,['make',(f'./metal_queue {name} 5' if name=='a' else "/bin/sh -c './metal_queue b 5'"),'mkdir -p subdir','cd subdir','pwd','echo bridge_stderr >&2; exit 7']) for iid,name in [(a,'a'),(b,'b')]]
    # External command in same sandbox while Claude is alive.
    require(h.execute(a,['/bin/echo','parallel_console']).strip()==b'parallel_console','same-instance console')
    results=[h.wait(j) for j in jobs]
    (h.output/'results.json').write_text(json.dumps(results,indent=2))
    (h.output/'seen.json').write_text(json.dumps(seen,indent=2))
    require(all(r['state']=='succeeded' for r in results),'sessions completed')
    require(all(len(seen[name])==6 for name in ['a','b']),'all Bash calls returned')
    import re
    builds=[];metals=[]
    for name in ['a','b']:
        values=seen[name]
        timing=re.search(r'TIMING make (\d+) (\d+)',values[0]['content']);require(timing,'make successful');builds.append(tuple(map(int,timing.groups())))
        finished=next(json.loads(line) for line in values[1]['content'].splitlines() if line.startswith('{') and json.loads(line).get('event')=='finished')
        require(finished['correctness']=='PASS' and finished['gpu_s']>0,'real Metal shader passed');metals.append((finished['start_monotonic_s'],finished['end_monotonic_s']))
        require('/workspace/subdir' in values[4]['content'],'Claude cwd persistence')
        require('Exit code 7' in values[5]['content'] and 'bridge_stderr' in values[5]['content'],'nonzero stderr')
    require(min(v[1] for v in builds)-max(v[0] for v in builds)>500000000,'Claude make calls did not overlap; annotation/classification broken')
    metals.sort();require(metals[0][1]<=metals[1][0],'Claude Metal calls overlapped')
    require(not h.call('status')['status'].get('recoveryReason'),'no quarantine')
    h.check('two Claude sessions: parallel builds, both policies share serial real Metal, cwd/streams/exit codes, same-instance console')
    job=launch(a,'tool_timeout',['printf started > tool_timeout.txt; sleep 60','echo after_tool_timeout'])
    require(h.wait(job)['state']=='succeeded','Claude session continues after Bash timeout')
    require('Command timed out' in seen['tool_timeout'][0]['content'] and 'after_tool_timeout' in seen['tool_timeout'][1]['content'],'timeout observation and recovery')
    h.execute(a,['/bin/sh','-c','echo serial_after_timeout'])
    h.check('Claude Bash timeout cancels parallel compound shell, retains output and permits next command')
    job=launch(a,'cancel',['printf started > cancel_ready.txt; sleep 60'])
    for _ in range(200):
        try:
            if h.read(a,'cancel_ready.txt')==b'started':break
        except RuntimeError:pass
        time.sleep(.05)
    else:raise AssertionError('cancellation fixture did not start')
    h.call('cancel',executionID=job)
    require(h.wait(job)['state']=='cancelled','operator cancellation result')
    h.execute(a,['/bin/sh','-c','echo serial_after_cancel'])
    require(not h.call('status')['status'].get('recoveryReason'),'clean cancellation must not quarantine')
    h.check('parent session cancellation cleans parallel compound shell and permits subsequent work')
    blocker=h.submit(b,['/bin/sh','-c','printf started > queue_blocker.txt; sleep 5'])
    for _ in range(100):
        try:
            if h.read(b,'queue_blocker.txt')==b'started':break
        except RuntimeError:pass
        time.sleep(.05)
    else:raise AssertionError('queue blocker did not start')
    job=launch(a,'queued',["/bin/sh -c 'exit 0'; printf forbidden > must_not_run.txt"])
    for _ in range(100):
        if 'queued' in seen:break
        time.sleep(.02)
    time.sleep(.3)
    h.call('cancel',executionID=job)
    require(h.wait(job)['state']=='cancelled','queued session cancellation')
    require(h.call('execution',executionID=blocker)['execution']['state']=='running','queued cancellation waited behind blocker')
    require(h.wait(blocker)['state']=='succeeded','unrelated blocker unaffected')
    h.execute(a,['/bin/sh','-c','test ! -e must_not_run.txt'])
    require(not h.call('status')['status'].get('recoveryReason'),'pre-grant cancellation must not quarantine')
    h.check('queued Claude tool cancellation retires before unrelated blocker; command never launches later')
    h.report['result']='passed' 
    (h.output/'tool_results.json').write_text(json.dumps(seen,indent=2))
    h.delete_owned()
except Exception as error:
    h.report['result']='failed';h.report['error']=repr(error)
    raise
finally:
    server.shutdown()
    if h.process and h.process.poll() is None:
        h.call('shutdown');h.process.wait(timeout=60)
    (h.output/'report.json').write_text(json.dumps(h.report,indent=2)+'\n')
