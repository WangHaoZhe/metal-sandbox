#!/usr/bin/env python3
"""Run the same native Metal program in two sandboxes through the public CLI.

Creates and retains two instances by default. To reuse them, pass both IDs.
Does not start/stop the service, read private state or execute Metal on the host.
"""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=Path('/Applications/Metal Sandbox.app/Contents/Helpers/sandboxctl'))
    parser.add_argument('--seconds', type=int, default=20, choices=range(5, 61), metavar='5..60')
    parser.add_argument('--sandbox-a')
    parser.add_argument('--sandbox-b')
    args = parser.parse_args()
    if bool(args.sandbox_a) != bool(args.sandbox_b):
        parser.error('provide both --sandbox-a and --sandbox-b, or neither')
    cli = [str(args.cli.expanduser().resolve()), 'sandbox']
    source = Path(__file__).resolve().with_name('metal_queue.mm')

    def run(*words, timeout=180):
        result = subprocess.run(cli + list(words), capture_output=True, text=True,
                                timeout=timeout, start_new_session=True)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result.stdout

    def call(*words):
        return json.loads(run(*words))

    status = call('status')['status']
    if status.get('recoveryReason') or status['pendingExecutions']:
        raise RuntimeError('请先确保服务健康、待完成命令为 0；本示例不会停止其他任务或自动恢复节点。')
    if args.sandbox_a:
        instances = [call('inspect', identifier)['instance'] for identifier in (args.sandbox_a, args.sandbox_b)]
        if instances[0]['id'] == instances[1]['id'] or any(i['state'] != 'active' for i in instances):
            raise RuntimeError('请选择两个不同的活动 Sandbox。')
    else:
        instances = call('create', '--count', '2')['instances']
    ids = [instance['id'] for instance in instances]
    print(f'Sandbox A: {ids[0]}\nSandbox B: {ids[1]}', flush=True)
    print('实例及 gpu_queue_demo/ 文件会保留；复用命令：', flush=True)
    print(shlex.join(['python3', str(Path(__file__).resolve()), '--cli', str(args.cli),
                      '--sandbox-a', ids[0], '--sandbox-b', ids[1], '--seconds', str(args.seconds)]), flush=True)
    for label, identifier in zip(('A', 'B'), ids):
        print(f'准备 {label}：上传同一份源码，在 sandbox 内编译……', flush=True)
        run('write', identifier, 'gpu_queue_demo/metal_queue.mm', '--from', str(source))
        run('exec', identifier, '--timeout', '120', '--', 'clang++',
            'gpu_queue_demo/metal_queue.mm', '-std=c++17', '-O2', '-fobjc-arc',
            '-framework', 'Foundation', '-framework', 'Metal', '-o', 'gpu_queue_demo/metal_queue')

    print(f'开始演示：连续提交 A、B，每个持续约 {args.seconds} 秒的真实 Metal 计算；不等 A 完成才提交 B。', flush=True)
    jobs = {}
    for label, identifier in zip(('A', 'B'), ids):
        job = call('exec', identifier, '--timeout', str(args.seconds + 60), '--detach', '--',
                   './gpu_queue_demo/metal_queue', label, str(args.seconds))['execution']['id']
        jobs[label] = job
        print(f'{label} 已提交，执行 ID：{job}', flush=True)
    # These processes only observe already-submitted executions; they do not
    # determine launch order. Isolate Ctrl-C so it cannot cancel GPU work.
    observers = {}
    results = {}
    counts = []
    try:
        for label, job in jobs.items():
            observers[label] = subprocess.Popen(cli + ['wait', job], stdout=subprocess.PIPE,
                                                stderr=subprocess.PIPE, text=True, start_new_session=True)
        deadline = time.monotonic() + 2 * (args.seconds + 60) + 300
        while len(results) < 2:
            status = call('status')['status']
            if status.get('recoveryReason'):
                raise RuntimeError('节点已隔离：' + status['recoveryReason'])
            count = status['pendingExecutions']
            if not counts or count != counts[-1]:
                counts.append(count)
                print(f'待完成命令 = {count}（运行中 + 排队中）', flush=True)
            for label, observer in observers.items():
                if label in results or observer.poll() is None:
                    continue
                stdout, stderr = observer.communicate()
                if observer.returncode:
                    raise RuntimeError(f'{label} 执行失败：{stderr}\n{stdout}')
                records = [json.loads(line) for line in stdout.splitlines() if line.strip()]
                result = next(record for record in records if record['event'] == 'finished')
                if result['correctness'] != 'PASS' or result['dispatches'] < 1:
                    raise RuntimeError(f'{label} 没有完成有效 Metal 计算')
                results[label] = result
                print(f"{label} 完成：{result['started_at']} → {result['finished_at']}，"
                      f"耗时 {result['elapsed_s']:.2f}s，GPU {result['gpu_s']:.2f}s，"
                      f"{result['dispatches']} 次 dispatch，{result['device']}，readback PASS", flush=True)
            if time.monotonic() > deadline:
                raise RuntimeError('观察超时；不自动取消或重试，请凭执行 ID 使用 sandbox wait 检查。')
            if len(results) < 2:
                time.sleep(0.5)
    finally:
        for observer in observers.values():
            if observer.poll() is None:
                observer.terminate()  # Stop only our CLI observer, never the candidate.
            observer.communicate(timeout=5)
    gap = results['B']['start_monotonic_s'] - results['A']['end_monotonic_s']
    if gap < 0:
        raise RuntimeError('FAIL：两个候选程序的运行时间发生重叠。')
    print(f'PASS：B 在 A 结束后 {gap:.3f}s 才开始。不是两个 GPU 程序并行运行。', flush=True)
    print('观察到的待完成数：' + ' → '.join(map(str, counts)), flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit('已停止观察；已提交命令仍由服务执行，不会自动取消。')
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError, StopIteration) as error:
        raise SystemExit(str(error))
