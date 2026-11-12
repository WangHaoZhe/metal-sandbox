#!/usr/bin/env python3
"""Verify default task lanes using real builds inside two managed App Sandboxes.

The timed fixture is CPU-only. Its monotonic timestamps prove child execution
overlap, not merely simultaneous submissions. This is not a GPU exclusivity test.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import time
from native_management_acceptance import Harness, require


STAMP = b'''#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
static unsigned long long now(void) {
  struct timespec t; if(clock_gettime(CLOCK_MONOTONIC,&t)) exit(2);
  return (unsigned long long)t.tv_sec*1000000000ULL+t.tv_nsec;
}
int main(int argc,char**argv) {
  if(argc!=3)return 1;
  unsigned long long start=now();
  usleep((unsigned)(atof(argv[2])*1000000));
  printf("TIMING %s %llu %llu\\n",argv[1],start,now());return 0;
}
'''
MAKE = b'''.PHONY: all
all:
\t$(CC) stamp.c -o stamp
\t./stamp make 2
'''
NINJA = b'''rule measure
  command = clang stamp.c -o stamp && ./stamp ninja 2
build force: phony
build measured: measure force
default measured
'''
CMAKE = b'''cmake_minimum_required(VERSION 3.20)
project(scheduling_check C)
add_executable(stamp stamp.c)
add_custom_target(measured ALL COMMAND $<TARGET_FILE:stamp> cmake 2 DEPENDS stamp)
'''


def completed(h, job, lane):
    record = h.wait(job)
    require(record['state'] == 'succeeded', str(record))
    require(record.get('scheduling') == lane, f'expected {lane}: {record}')
    return record


def interval(record):
    stdout = base64.b64decode(record['result']['stdout']).decode()
    matches = re.findall(r'^TIMING (\S+) (\d+) (\d+)$', stdout, re.MULTILINE)
    require(len(matches) == 1, stdout)
    label, start, end = matches[0]
    require(int(end) > int(start), 'positive monotonic interval')
    return label, int(start), int(end)


def run(h):
    def counts(expected, instance_id=None):
        end = time.monotonic() + 5
        while True:
            reply = (h.call('inspect', instanceID=instance_id)['instance'] if instance_id else h.call('status')['status'])
            actual = reply.get('executionCounts')
            require(actual is not None and sum(actual.values()) == reply['pendingExecutions'], 'count breakdown must sum to the same snapshot total')
            require(actual['serialRunning'] <= 1 and all(v >= 0 for v in actual.values()), 'nonnegative counters and one running serial task')
            if actual == expected: return
            require(time.monotonic() < end, f'expected {expected}, got {actual}')
            time.sleep(.01)
    def breakdown(pr=0, pw=0, sr=0, sw=0):
        return dict(parallelRunning=pr, parallelWaiting=pw, serialRunning=sr, serialWaiting=sw)
    try:
        status = h.start()
        require(status['toolchain'].get('cmake') and status['toolchain'].get('ninja'), 'install CMake and Ninja before acceptance')
        require(status.get('perInstanceTaskPolicyImplemented'), 'per-instance policy capability')
        h.report['policy'] = status['taskPolicy']
        a, b = [r['id'] for r in h.call('create', count=2)['instances']]
        for iid in (a, b):
            require(h.call('inspect', instanceID=iid)['instance']['taskPolicy'] == status['taskPolicy'], 'default snapshotted into instance')
            for path, data in [('stamp.c', STAMP), ('Makefile', MAKE), ('build.ninja', NINJA), ('CMakeLists.txt', CMAKE)]:
                h.write(iid, path, data)
            h.write(iid, 'identity.txt', iid.encode())
            h.execute(iid, ['clang', 'stamp.c', '-o', 'stamp'])
            h.execute(iid, ['cmake', '-S', '.', '-B', 'build', '-G', 'Ninja'])
        h.report['parallelBuilds'] = []
        for argv in [['make'], ['ninja'], ['cmake', '--build', 'build']]:
            jobs = [h.submit(iid, argv) for iid in (a, b)]
            counts(breakdown(pr=2))
            for iid in (a, b): counts(breakdown(pr=1), iid)
            records = [completed(h, job, 'parallel') for job in jobs]
            windows = [interval(record) for record in records]
            overlap = min(w[2] for w in windows) - max(w[1] for w in windows)
            require(overlap > 500_000_000, f'{argv}: no substantial actual execution overlap: {windows}')
            require(records[0]['result']['leaseID'] != records[1]['result']['leaseID'], 'independent leases')
            h.report['parallelBuilds'].append({'argv': argv, 'records': records, 'overlapNanoseconds': overlap})
            h.check('default parallel real build: ' + ' '.join(argv))

        # Static compound scripts retain their shell semantics, but each
        # component must match the allowlist (including argument prefixes).
        for script in ['make && echo done', 'make | cat', 'make; echo done\ncat identity.txt']:
            records = [completed(h, job, 'parallel') for job in
                       [h.submit(iid, ['/bin/bash', '-c', script]) for iid in (a, b)]]
            windows = [interval(r) for r in records]
            require(min(w[2] for w in windows) - max(w[1] for w in windows) > 500_000_000,
                    'allowlisted compound scripts did not overlap: ' + script)
        h.check('all-allowlisted && / pipe / semicolon / multiline tasks overlap in actual sandbox execution')

        # Exercise the same PreToolUse annotation + shell-prefix helper used by
        # Claude, without downloading a CLI or requiring a model/API key.
        def bridge(iid, raw, name):
            h.write(iid, name + '.json', json.dumps({'tool_input': {'command': raw}}).encode())
            script = r'''#!/bin/bash
set -eu
# Keep the task setup's real PATH: the managed helper is searched first.
export PATH="${METAL_SANDBOX_SHELL_HELPER%/*}:$PATH"
"$METAL_SANDBOX_SHELL_HELPER" "'$METAL_SANDBOX_SHELL_HELPER' --hook 'claude'" < INPUT > REPLY
id=$(sed -n 's/.*metal-sandbox-tool:\([0-9a-f-]*\).*/\1/p' REPLY)
"$METAL_SANDBOX_SHELL_HELPER" "# metal-sandbox-tool:$id
RAW"
'''.replace('INPUT', name + '.json').replace('REPLY', name + '_reply.json').replace('RAW', raw)
            h.write(iid, name + '.sh', script.encode())
            return h.call('exec', instanceID=iid, command={'argv': ['/bin/bash', './' + name + '.sh'],
                'cwd': '.', 'timeoutSeconds': 30, 'maxLogBytes': 1048576, 'agentSession': True})['execution']['id']
        jobs = [bridge(iid, 'make && echo bridge_done', 'bridge_parallel') for iid in (a, b)]
        counts(breakdown(pr=4)) # Two harness sessions plus their two Bash tools.
        for iid in (a, b): counts(breakdown(pr=2), iid)
        records = [completed(h, job, 'parallel') for job in jobs]
        windows = [interval(r) for r in records]
        require(min(w[2] for w in windows) - max(w[1] for w in windows) > 500_000_000, 'Bash adapter compound tasks did not overlap')
        require(all(b'bridge_done' in base64.b64decode(r['result']['stdout']) for r in records), 'Bash adapter retains shell output')
        require(all(b'Waiting for the shared serial slot' not in base64.b64decode(r['result']['stderr']) for r in records),
                'managed helper PATH must not make allowlisted Bash tasks serial')
        records = [completed(h, job, 'parallel') for job in
                   [bridge(iid, 'echo begin; ./stamp bridge_serial 0.5', 'bridge_serial') for iid in (a, b)]]
        windows = sorted(interval(r)[1:] for r in records)
        require(windows[0][1] <= windows[1][0], 'unlisted Bash adapter component escaped serial lane')
        require(all(b'Waiting for the shared serial slot' in base64.b64decode(r['result']['stderr']) for r in records), 'Bash adapter must acquire serial lease')
        h.check('PreToolUse annotation/shell-prefix path: all allowed overlaps, mixed compounds share serial lane')

        # One unlisted component keeps the whole script serial.
        jobs = [h.submit(iid, ['/bin/sh', '-c', f'echo ninja; ./stamp serial_{n} 0.4']) for n, iid in enumerate((a, b))]
        counts(breakdown(sr=1, sw=1))
        records = [completed(h, job, 'serial') for job in jobs]
        windows = [interval(record) for record in records]
        require(windows[0][2] <= windows[1][1], 'non-allowlisted shell tasks must not overlap')
        h.report['serialTasks'] = records
        h.check('non-allowlisted shell remains FIFO; mentioning ninja does not allow it')

        # Wait for a durable grant, then prove short operations and compilation
        # finish while an unrelated serial task still runs in another sandbox.
        blocker = h.submit(a, ['./stamp', 'blocker', '5'])
        for _ in range(100):
            if (h.coord/'active-lease.json').exists():
                break
            time.sleep(0.02)
        else:
            raise AssertionError('serial fixture did not acquire lease')
        read = completed(h, bridge(b, 'ls && cat identity.txt', 'bridge_read'), 'parallel')
        require(h.call('execution', executionID=blocker)['execution']['state'] == 'running', 'bare Claude ls/cat waited behind serial work')
        require(b.encode() in base64.b64decode(read['result']['stdout']), 'Claude read used the correct sandbox cwd')
        require(b'Waiting for the shared serial slot' not in base64.b64decode(read['result']['stderr']), 'bare Claude ls/cat entered serial lane')
        h.report['claudeReadAlongsideSerial'] = read
        checks = []
        for argv in [['ls'], ['cat', 'identity.txt'], ['sleep', '.1'], ['echo', 'parallel'],
                     ['head', '-n', '1', 'identity.txt'], ['grep', b, 'identity.txt'],
                     ['sed', '-n', '1p', 'identity.txt'], ['find', '.', '-name', 'identity.txt'],
                     ['/bin/bash', '-c', 'sleep .1 && cat identity.txt | cat'],
                     ['git', '--version'], ['clang', 'stamp.c', '-o', 'second_stamp']]:
            record = completed(h, h.submit(b, argv), 'parallel')
            require(h.call('execution', executionID=blocker)['execution']['state'] == 'running', 'parallel work blocked behind serial task')
            checks.append(record)
        require(base64.b64decode(checks[1]['result']['stdout']) == b.encode(), 'output belongs to correct sandbox')
        h.report['alongsideSerial'] = checks
        completed(h, blocker, 'serial')
        counts(breakdown())
        h.check('default sleep/file/text/git/compiler tasks complete alongside serial work; outputs stay isolated')

        # The same instance must not add a second serialization layer.
        blocker = h.submit(a, ['/bin/sh', '-c', './stamp same_instance_serial 2'])
        for _ in range(100):
            if (h.coord/'active-lease.json').exists(): break
            time.sleep(.02)
        direct = completed(h, h.submit(a, ['/bin/sleep', '.1']), 'parallel')
        compound = completed(h, h.submit(a, ['/bin/bash', '-c', 'ls && cat identity.txt']), 'parallel')
        require(a.encode() in base64.b64decode(compound['result']['stdout']), 'same-instance compound classification while busy')
        require(h.call('execution', executionID=blocker)['execution']['state'] == 'running', 'same-instance parallel command waited for serial task')
        completed(h, blocker, 'serial')
        started = time.monotonic()
        sleepers = [h.submit(a, ['/bin/sleep', '1']) for _ in range(2)]
        for job in sleepers: completed(h, job, 'parallel')
        require(time.monotonic()-started < 1.8, 'same-instance parallel commands were serialized')
        sleeper = h.submit(a, ['/bin/sleep', '3'])
        first = completed(h, h.submit(a, ['/bin/sh', '-c', './stamp serial_with_parallel .1']), 'serial')
        completed(h, h.submit(b, ['/bin/sh', '-c', './stamp neighbor_serial .1']), 'serial')
        require(h.call('execution', executionID=sleeper)['execution']['state'] == 'running', 'busy instance blocked global serial progress')
        completed(h, sleeper, 'parallel')
        h.check('same-instance parallel tasks overlap; parallel and serial tasks coexist; no instance-lock head-of-line blocking')

        # Build descendants deliberately inherit the parallel task's lane.
        # A failed compiler is a completed task, not an uncertain GPU cleanup.
        h.write(b, 'stamp.c', b'#error intentional_scheduling_failure\n')
        failed = h.wait(h.submit(b, ['make']))
        require(failed['state'] == 'failed' and failed['scheduling'] == 'parallel', str(failed))
        require(b'intentional_scheduling_failure' in base64.b64decode(failed['result']['stderr']), 'build diagnostics retained')
        require(not h.call('status')['status'].get('recoveryReason'), 'ordinary build failure must not quarantine')
        h.write(b, 'stamp.c', STAMP)
        completed(h, h.submit(b, ['make']), 'parallel')
        h.check('parallel build failure preserves diagnostics and permits retry')

        # Timeouts are task failures, not node failures once the group is gone.
        # Exercise TERM, KILL, a TERM handler exiting zero, both lanes, the same
        # Host, another sandbox and serial work already queued behind a timeout.
        hosts = {iid: h.call('inspect', instanceID=iid)['instance']['physical']['pid'] for iid in (a, b)}
        h.report['cleanedTimeouts'] = []
        for argv, lane in [(['sleep', '5'], 'parallel'),
                           (['/bin/sh', '-c', 'echo before_timeout; trap "echo term_cleanup; exit 0" TERM; while :; do sleep .05; done'], 'serial'),
                           (['/bin/sh', '-c', 'trap "" TERM; echo before_timeout; sleep 5 & wait'], 'serial')]:
            timed_job = h.submit(a, argv, timeout=.5)
            # A different sandbox must survive, whether concurrent or queued.
            peer_job = h.submit(b, ['/bin/sh', '-c', 'sleep .7; echo peer_completed'])
            next_job = h.submit(a, ['echo', 'same_host_continues'])
            timed = h.wait(timed_job)
            outcome = timed['result']['outcome']
            require(timed['state'] == 'failed' and timed['scheduling'] == lane, str(timed))
            require(outcome['reason'] == 'timedOut' and outcome['processGroupGone'], str(outcome))
            require('timed out' in timed.get('error', ''), 'explicit timeout diagnostic')
            require(not h.call('status')['status'].get('recoveryReason'), 'cleaned timeout quarantined node')
            if 'term_cleanup' in ' '.join(argv):
                require(outcome.get('exitCode') == 0, 'TERM handler exits zero without turning timeout into success')
                require(b'term_cleanup' in base64.b64decode(timed['result']['stdout']), 'TERM cleanup output retained')
            if 'trap ""' in ' '.join(argv):
                require(outcome.get('terminationSignal') == 9, 'TERM-resistant fixture required KILL')
            completed(h, peer_job, 'parallel')
            completed(h, next_job, 'parallel')
            require(all(h.call('inspect', instanceID=iid)['instance']['physical']['pid'] == pid for iid, pid in hosts.items()), 'Hosts reused after timeout')
            h.report['cleanedTimeouts'].append(timed)
        cli_timeout = h.cli('exec', a, '--timeout', '.5', '--', '/bin/sh', '-c',
                            'trap "exit 0" TERM; while :; do sleep .05; done', success=False)
        require(cli_timeout.returncode != 0 and b'timed out' in cli_timeout.stderr, 'CLI reports failed timeout even with zero exit handler')
        require(h.execute(a, ['echo', 'CLI_retry']) == b'CLI_retry\n', 'CLI timeout leaves sandbox usable')
        require(not (h.coord/'active-lease.json').exists() and not list((h.coord/'parallel_leases').glob('*')), 'cleaned timeouts leave no stale leases')
        h.check('cleaned TERM/KILL timeouts fail without quarantine; same/other Host, queued work, logs and CLI remain usable')
        h.delete_owned()

        h.call('shutdown'); h.process.wait(timeout=30)
        policy = h.output/'serial_policy.json'
        policy.write_text('{"parallel":[]}\n')
        require(h.start('--task-policy', str(policy))['taskPolicy']['parallel'] == [], 'operator policy replaces defaults')
        ids = [r['id'] for r in h.call('create', count=2)['instances']]
        for iid in ids:
            h.write(iid, 'stamp.c', STAMP)
            h.write(iid, 'Makefile', MAKE)
        records = [completed(h, job, 'serial') for job in [h.submit(iid, ['make']) for iid in ids]]
        windows = [interval(record) for record in records]
        require(windows[0][2] <= windows[1][1], 'empty policy makes make serial again')
        h.report['operatorSerialBuilds'] = records
        h.check('operator empty policy replaces defaults; make returns to serial execution')

        # CLI uploads a snapshot of this JSON. It is not a mutable shared file.
        custom = {'parallel': [{'executable': '/bin/sleep', 'argumentPrefix': []}]}
        policy.write_text(json.dumps(custom))
        created = subprocess.run([str(h.binary/'sandboxctl'), '--state-dir', str(h.state), 'sandbox',
            'create', '--count', '1', '--task-policy', str(policy)], capture_output=True, text=True)
        require(created.returncode == 0, created.stderr)
        instance = json.loads(created.stdout)['instances'][0]
        custom_id = instance['id']
        require(instance['taskPolicy'] == custom, 'CLI policy reaches instance record')
        policy.write_text('{"parallel":[]}')
        require(h.call('inspect', instanceID=custom_id)['instance']['taskPolicy'] == custom, 'editing source JSON cannot change a created instance')
        before = len(h.call('list')['instances'])
        for malformed in ['{', '{"parallel":[{"executable":"sleep"}]}',
                          '{"parallel":[],"serial":[]}', '{"serial":null}',
                          '{"parallel":[{"executable":"/bin/sleep","argumentprefix":["1"]}]}']:
            policy.write_text(malformed)
            rejected = subprocess.run([str(h.binary/'sandboxctl'), '--state-dir', str(h.state), 'sandbox',
                'create', '--count', '1', '--task-policy', str(policy)], capture_output=True, text=True)
            require(rejected.returncode != 0, 'invalid JSON must not create a sandbox')
        require(len(h.call('list')['instances']) == before, 'invalid policy allocates no instances')
        h.reject('create', count=1, taskPolicy=custom, auth=False)
        blocker = h.submit(ids[0], ['./stamp', 'custom_policy_blocker', '3'])
        for _ in range(100):
            if (h.coord/'active-lease.json').exists(): break
            time.sleep(.02)
        else: raise AssertionError('serial lease not granted')
        queued = h.submit(ids[1], ['./stamp', 'empty_policy_queued', '.1'])
        completed(h, h.submit(custom_id, ['/bin/sleep', '.1']), 'parallel')
        require(h.call('execution', executionID=blocker)['execution']['state'] == 'running', 'custom policy overrides empty service default at both scheduler layers')
        first = completed(h, blocker, 'serial'); second = completed(h, queued, 'serial')
        require(interval(first)[2] <= interval(second)[1], 'empty per-instance policies still share serial lane')
        completed(h, h.submit(custom_id, ['/bin/echo', 'not allowed']), 'serial')
        for seconds in (10, 7200, 172800):
            result = completed(h, h.submit(custom_id, ['/bin/echo', 'timeout accepted'], timeout=seconds), 'serial')
            require(result['command']['timeoutSeconds'] == seconds, 'positive timeout preserved without 30/3600-second cap')
        h.check('per-instance JSON: custom parallel lane, empty serial lane, malformed rejection, authority and positive timeout')

        # Blocklists choose the same shared serial lane; unmatched whole tasks
        # (including their children) are parallel, not intercepted at GPU calls.
        blocked = {'serial': [{'executable': '/bin/sh', 'argumentPrefix': []}]}
        policy.write_text(json.dumps(blocked))
        black = json.loads(h.cli('create', '--count', '2', '--task-policy', str(policy)).stdout)['instances']
        black_ids = [r['id'] for r in black]
        require(all(r['taskPolicy'] == blocked for r in black), 'CLI blocklist preserved for all created instances')
        for iid in black_ids:
            h.write(iid, 'stamp.c', STAMP)
            completed(h, h.submit(iid, ['clang', 'stamp.c', '-o', 'stamp']), 'parallel')
        records = [completed(h, job, 'serial') for job in
                   [h.submit(iid, ['/bin/sh', '-c', './stamp blocked .4']) for iid in black_ids]]
        require(interval(records[0])[2] <= interval(records[1])[1], 'blocklisted tasks never overlap')
        h.report['blocklistedSerial'] = records
        records = [completed(h, job, 'parallel') for job in
                   [h.submit(iid, ['/usr/bin/env', '/bin/sh', '-c', './stamp unmatched 1.5']) for iid in black_ids]]
        windows = [interval(r) for r in records]
        require(min(w[2] for w in windows) - max(w[1] for w in windows) > 500_000_000, 'unmatched tasks really overlap; child sh not reclassified')
        h.report['blocklistUnmatchedParallel'] = records
        records = [completed(h, job, 'serial') for job in [h.submit(ids[0], ['./stamp', 'allowlist_serial', '.4']),
                   h.submit(black_ids[0], ['/bin/sh', '-c', './stamp blocklist_serial .4'])]]
        require(interval(records[0])[2] <= interval(records[1])[1], 'both policy modes use the same serial slot')
        empty_black = h.call('create', count=1, taskPolicy={'serial': []})['instances'][0]['id']
        completed(h, h.submit(empty_black, ['/bin/sh', '-c', 'echo empty_blacklist']), 'parallel')
        h.check('blocklists: matched serial, unmatched actual overlap, shared slot, whole-task descendants and empty policy')
        for record in h.call('list')['instances']:
            if record['state'] == 'active': h.call('stop', instanceID=record['id'])
        h.call('shutdown'); h.process.wait(timeout=30)
        restarted = h.start()
        require(restarted['taskPolicy']['parallel'], 'restart returns to shipped JSON default')
        for iid, expected in [(custom_id, custom), (ids[0], {'parallel': []}), (black_ids[0], blocked), (empty_black, {'serial': []})]:
            require(h.call('inspect', instanceID=iid)['instance']['taskPolicy'] == expected, 'policy survives service restart')
            restored = h.call('restore', instanceID=iid)['instance']
            require(restored['taskPolicy'] == expected, 'restore preserves policy even when service default changes')
        h.check('inspect/list retain stopped policies; restart and restore preserve both modes and empty snapshots')
        h.delete_owned()
        h.report['result'] = 'passed'
    except Exception as error:
        h.report['result'] = 'failed'; h.report['error'] = repr(error)
        raise
    finally:
        if h.process and h.process.poll() is None:
            h.call('shutdown'); h.process.wait(timeout=30)
        h.report['activeLeaseRemains'] = (h.coord/'active-lease.json').exists()
        h.report['parallelLeasesRemain'] = [p.name for p in (h.coord/'parallel_leases').glob('*')]
        (h.output/'report.json').write_text(json.dumps(h.report, indent=2)+'\n')
        for log in h.logs: log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if os.getuid() == 0: raise SystemExit('do not run as root')
    run(Harness(args.bin_dir, args.output))
