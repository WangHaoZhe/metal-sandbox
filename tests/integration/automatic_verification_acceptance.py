import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--bin-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
binary = args.bin_dir.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
temporary = output / 'runtime_tmp'
temporary.mkdir()
state = output / 'state'
environment = {**os.environ, 'TMPDIR': str(temporary) + '/'}
checks = []


def cli(*arguments, success=True, decode=True):
    process = subprocess.run([str(binary / 'sandboxctl'), '--state-dir', str(state), 'sandbox', *arguments],
                             env=environment, capture_output=True, timeout=180)
    if success:
        assert process.returncode == 0, process.stderr.decode(errors='replace')
    else:
        assert process.returncode != 0, arguments
    return json.loads(process.stdout) if decode and success else process


def save(name, value):
    (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2))


def check(name):
    checks.append(name)
    save('checks.json', checks)
    print('PASS:', name, flush=True)


def start():
    log = (output / ('service_' + str(time.time_ns()) + '.log')).open('wb')
    process = subprocess.Popen([str(binary / 'metal-sandboxd'), '--allow-trusted-code',
                                '--bin-dir', str(binary), '--state-dir', str(state)],
                               env=environment, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
    log.close()
    deadline = time.monotonic() + 60
    while True:
        assert process.poll() is None, '测试服务启动失败'
        # 启动探测使用公开 CLI，连接就绪前不提交操作。
        result = subprocess.run([str(binary / 'sandboxctl'), '--state-dir', str(state), 'sandbox', 'status'],
                                env=environment, capture_output=True, timeout=5)
        if result.returncode == 0:
            reply = json.loads(result.stdout)
            assert reply['status']['stateDirectory'] == str(state)
            return process
        assert time.monotonic() < deadline, result.stderr.decode(errors='replace')
        time.sleep(0.1)


def execute(iid, command, session=False, timeout=30):
    return cli('exec', iid, '--detach', '--timeout', str(timeout),
               *(['--session'] if session else []), '--', *command)['execution']


def wait(eid):
    deadline = time.monotonic() + 120
    while True:
        record = cli('execution', eid)['execution']
        if record['state'] in ['succeeded', 'failed', 'cancelled', 'interrupted']:
            save(eid + '.json', record)
            return record
        assert time.monotonic() < deadline, record
        time.sleep(0.1)


def auto_result(parent):
    parent = wait(parent['id'])
    deadline = time.monotonic() + 120
    while True:
        parent = cli('execution', parent['id'])['execution']
        plan = parent['automaticVerification']
        assert plan['state'] in ['waiting', 'submitted'], plan
        if plan['state'] == 'submitted':
            result = wait(plan['executionID'])
            assert result['agentExecutionID'] == parent['id']
            return result
        assert time.monotonic() < deadline, parent
        time.sleep(0.1)


service = start()
try:
    task = output / 'task'
    shutil.copytree(ROOT / 'tests/fixtures/automatic_verification', task)
    instances = cli('create', '--count', '6', '--no_network')['instances']
    save('instances.json', instances)
    ids = [item['id'] for item in instances]
    for iid in ids:
        cli('import', iid, '--from', str(task), '--task', decode=False)
        names = [entry['name'] for entry in cli('ls', iid)['directory']['entries']]
        assert 'tests' not in names
    settings = [cli('verification', iid)['verificationSettings'] for iid in ids]
    assert all(item['enabled'] for item in settings)
    assert len({item['testPackageSHA256'] for item in settings}) == 1
    assert len(list((state / 'test_packages').glob('*/tests.zip'))) == 1
    check('导入时隐藏 tests，六个副本共用同一份存档')
    task.rename(output / 'moved_task')
    check('原题包移动后继续使用已保存的 tests')

    successful = execute(ids[0], ['/bin/sh', './setup.sh'], session=True)
    failed = execute(ids[1], ['/bin/sh', '-c', 'sh ./setup.sh; exit 7'], session=True)
    timeout = execute(ids[2], ['/bin/sh', '-c', 'sh ./setup.sh; sleep 30'], session=True, timeout=2)
    for parent in [successful, failed, timeout]:
        result = auto_result(parent)
        assert result['state'] == 'succeeded', result
        assert result['metricsSaved']
        assert base64.b64decode(result['result']['stdout']).strip() == b'sum=5050'
    assert wait(failed['id'])['result']['outcome']['exitCode'] == 7
    assert wait(timeout['id'])['result']['outcome']['reason'] == 'timedOut'
    check('真实编译计算完成、非零退出及清理后的超时均触发验收，结果分别保存')

    cancelled = execute(ids[3], ['/bin/sleep', '30'], session=True)
    cli('cancel', cancelled['id'])
    assert wait(cancelled['id'])['state'] == 'cancelled'
    time.sleep(0.5)
    assert cli('execution', cancelled['id'])['execution']['automaticVerification']['state'] == 'cancelled'
    assert 'tests' not in [entry['name'] for entry in cli('ls', ids[3])['directory']['entries']]
    check('主动取消不注入 tests、不启动验收')

    blocker = execute(ids[3], ['/bin/sleep', '3'])
    completed = execute(ids[3], ['/bin/sh', './setup.sh'], session=True)
    assert wait(completed['id'])['state'] == 'succeeded'
    cli('cancel', completed['id'])
    wait(blocker['id'])
    time.sleep(0.5)
    assert cli('execution', completed['id'])['execution']['automaticVerification']['state'] == 'cancelled'
    assert not any(item.get('verification') for item in cli('executions', '--instance', ids[3])['executions'])
    check('Agent 已结束但验收尚在等待时，取消仍阻止后续测试提交')

    cli('verification', ids[4], '--enabled', 'false')
    disabled = execute(ids[4], ['/bin/sh', './setup.sh'], session=True)
    assert 'automaticVerification' not in wait(disabled['id'])
    cli('verify', ids[4], '--after', disabled['id'], '--detach')
    assert auto_result(disabled)['state'] == 'succeeded'
    cli('verify', ids[4], '--after', disabled['id'], '--detach', success=False)
    check('关闭自动验收、按执行 ID 追加验收及拒绝重复注册')

    # 持续并行任务用于验证实例空闲条件，不占用全局串行执行位置。
    blocker = execute(ids[5], ['/bin/sleep', '15'])
    parent = execute(ids[5], ['/bin/sh', './setup.sh'], session=True)
    assert wait(parent['id'])['state'] == 'succeeded'
    time.sleep(0.5)
    assert cli('execution', parent['id'])['execution']['automaticVerification']['state'] == 'waiting'
    assert 'tests' not in [entry['name'] for entry in cli('ls', ids[5])['directory']['entries']]
    cli('shutdown')
    service.wait(timeout=120)
    service = start()
    assert auto_result(parent)['state'] == 'succeeded'
    check('等待同实例命令清理，服务重启后恢复尚未提交的验收')

    before = cli('executions', '--instance', ids[5])['executions']
    cli('shutdown')
    service.wait(timeout=120)
    service = start()
    time.sleep(1)
    after = cli('executions', '--instance', ids[5])['executions']
    assert [item['id'] for item in before] == [item['id'] for item in after]
    check('已提交验收在服务重启后不重复运行')

    for iid in ids[:3]:
        cli('start', iid)
    blocker = execute(ids[1], ['/bin/sh', '-c', 'sleep 6; ./sum'])
    deadline = time.monotonic() + 30
    while cli('execution', blocker['id'])['execution']['state'] != 'running':
        assert time.monotonic() < deadline
        time.sleep(0.05)
    verification = cli('verify', ids[0], '--detach')['execution']
    assert verification['scheduling'] == 'serial'
    cli('read', ids[0], 'sum.c', '--out', str(output / 'read_during_verification.c'), decode=False)
    assert (output / 'read_during_verification.c').read_bytes() == (ROOT / 'tests/fixtures/automatic_verification/agent/sum.c').read_bytes()
    cli('exec', ids[0], '--detach', '--', '/bin/ls', success=False)
    cli('write', ids[0], 'sum.c', '--from', str(output / 'read_during_verification.c'), success=False)
    parallel = wait(execute(ids[2], ['/bin/ls'])['id'])
    blocked = wait(blocker['id'])
    verified = wait(verification['id'])
    assert parallel['finishedAt'] < blocked['finishedAt']
    assert verified['startedAt'] >= blocked['finishedAt'] - 100
    assert verified['state'] == 'succeeded', verified
    check('验收串行排队期间允许读取，拒绝同实例执行和写入，其他实例并行命令继续执行')
    check('再次验收清除旧 tests 输出，重新编译运行成功')

    stopped = execute(ids[2], ['/bin/sleep', '30'], session=True)
    cli('stop', ids[2])
    assert wait(stopped['id'])['automaticVerification']['state'] == 'cancelled'
    time.sleep(0.5)
    assert cli('inspect', ids[2])['instance']['state'] == 'stopped'
    check('停止实例取消后续自动验收且不会自动重启')

    recovery_instances = cli('create', '--count', '2', '--no_network')['instances']
    candidate, victim = recovery_instances
    ids.extend(item['id'] for item in recovery_instances)
    cli('import', candidate['id'], '--from', str(output / 'moved_task'), '--task', decode=False)
    parent = execute(candidate['id'], ['/bin/sh', '-c',
        "sh ./setup.sh || exit; trap 'exit 0' USR1; echo $$ > ready; while :; do sleep 0.05; done"], session=True)
    child = execute(victim['id'], ['/bin/sh', '-c', 'echo $$ > ready; exec /bin/sleep 90'], timeout=100)
    processes = []
    for item in recovery_instances:
        deadline = time.monotonic() + 20
        while 'ready' not in [entry['name'] for entry in cli('ls', item['id'])['directory']['entries']]:
            assert time.monotonic() < deadline
            time.sleep(0.05)
        pid_file = output / (item['id'] + '.pid')
        cli('read', item['id'], 'ready', '--out', str(pid_file), decode=False)
        processes.append(int(pid_file.read_text()))
    assert os.getpgid(processes[1]) == processes[1]
    os.kill(victim['physical']['pid'], signal.SIGKILL)
    assert wait(child['id'])['state'] == 'failed'
    assert cli('status')['status'].get('recoveryReason')
    os.killpg(processes[1], signal.SIGKILL)
    deadline = time.monotonic() + 5
    while True:
        try:
            os.killpg(processes[1], 0)
        except ProcessLookupError:
            break
        assert time.monotonic() < deadline, '测试进程组仍然存在'
        time.sleep(0.01)
    cli('stop', victim['id'], success=False)
    os.kill(processes[0], signal.SIGUSR1)
    assert wait(parent['id'])['state'] == 'succeeded'
    time.sleep(0.5)
    assert cli('execution', parent['id'])['execution']['automaticVerification']['state'] == 'waiting'
    assert 'tests' not in [entry['name'] for entry in cli('ls', candidate['id'])['directory']['entries']]
    cli('recover', '--confirm-processes-cleaned', '--note',
        'Owned CPU-only test Host terminated; its child process group was killed and confirmed absent.')
    assert auto_result(parent)['state'] == 'succeeded'
    cli('start', victim['id'])
    cli('stop', victim['id'])
    check('真实 Host 失联后自动验收保持等待，人工恢复后继续执行')

    for iid in ids:
        record = cli('inspect', iid)['instance']
        if 'stop' in record['availableActions']:
            cli('stop', iid)
        cli('delete', iid, '--confirm')
        assert not (state / 'verification_settings' / (iid + '.json')).exists()
    assert cli('status')['status'].get('recoveryReason') is None
    check('全部测试实例删除，节点无异常隔离')
finally:
    if service.poll() is None:
        cli('shutdown')
        service.wait(timeout=120)
