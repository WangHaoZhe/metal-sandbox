#!/usr/bin/env python3
"""Real native development, nested execution and boundary regression acceptance.

Run alone under the normal same-UID coordination lock, never alongside a user's
service. Optional Metal checks use real GPU completion/readback, not FPS scores.
No quarantine stripping, automatic recovery or host candidate execution.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import socket
from native_management_acceptance import Harness, require

CMAKE = b'''cmake_minimum_required(VERSION 3.20)
project(native_development LANGUAGES C CXX)
try_run(PROBE_RUN PROBE_COMPILED ${CMAKE_BINARY_DIR}/probe ${CMAKE_CURRENT_SOURCE_DIR}/probe.c)
if(NOT PROBE_COMPILED OR NOT PROBE_RUN EQUAL 0)
  message(FATAL_ERROR "Internal compile/try_run failed: ${PROBE_COMPILED}/${PROBE_RUN}")
endif()
add_library(answer SHARED answer.cpp)
set_target_properties(answer PROPERTIES VERSION 1.2.3 SOVERSION 1)
add_executable(helper helper.cpp)
add_executable(project main.cpp)
target_link_libraries(helper PRIVATE answer)
target_link_libraries(project PRIVATE answer)
set_target_properties(helper project PROPERTIES BUILD_RPATH "@loader_path")
enable_testing()
add_test(NAME helper_test COMMAND helper)
add_test(NAME project_test COMMAND project $<TARGET_FILE:helper>)
'''
PROBE = b'int main(void) { return 0; }\n'
HELPER = b'extern int answer(); int main(){return answer() >= 40 ? 0 : 1;}\n'
MAIN = b'''#include <cstdlib>
#include <cstdio>
#include <string>
extern int answer();
int main(int argc, char**argv) {
  if(argc != 2) return 1;
  std::string command = "\\\"" + std::string(argv[1]) + "\\\"";
  if(std::system(command.c_str()) != 0) return 2;
  std::printf("RESULT=%d\\n",answer());return 0;
}
'''
BOUNDARY = b'''#include <sys/socket.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
int denied(const char *path,int mode) {
  int fd=open(path,mode); if(fd>=0){close(fd);return 0;}
  return errno==EPERM || errno==EACCES;
}
int main(int argc,char**argv) {
  if(argc!=6)return 1;
  int own=open("probe.c",O_RDONLY);if(own<0)return 2;close(own);
  for(int i=1;i<=3;++i)if(!denied(argv[i],O_RDONLY)||!denied(argv[i],O_WRONLY))return 3;
  int tool=open(argv[4],O_RDONLY);if(tool<0)return 4;close(tool);
  if(!denied(argv[4],O_WRONLY))return 5;
  int fd=socket(AF_INET,SOCK_STREAM,0);struct sockaddr_in a={0};
  a.sin_family=AF_INET;a.sin_port=htons(atoi(argv[5]));a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
  int r=connect(fd,(struct sockaddr*)&a,sizeof(a));int e=errno;if(fd>=0)close(fd);
  if(r==0 || (e!=EPERM && e!=EACCES))return 6;
  puts("GENERATED_BINARY_BOUNDARIES_OK");return 0;
}
'''

SHADER = b'''#include <metal_stdlib>
using namespace metal;
kernel void fill(device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i]=i*3+7; }
'''
METAL_RUNNER = b'''#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
int main(){@autoreleasepool {
  id<MTLDevice> device=MTLCreateSystemDefaultDevice();if(!device)return 1;
  NSError *error=nil;
  id<MTLLibrary> library=[device newLibraryWithURL:[NSURL fileURLWithPath:@"shader.metallib"] error:&error];
  if(!library){fprintf(stderr,"%s\\n",error.description.UTF8String);return 2;}
  id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"fill"] error:&error];
  if(!pipeline)return 3;
  id<MTLBuffer> output=[device newBufferWithLength:64*sizeof(unsigned) options:MTLResourceStorageModeShared];
  id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> buffer=[queue commandBuffer];
  id<MTLComputeCommandEncoder> encoder=[buffer computeCommandEncoder];
  [encoder setComputePipelineState:pipeline];[encoder setBuffer:output offset:0 atIndex:0];
  [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(32,1,1)];
  [encoder endEncoding];[buffer commit];[buffer waitUntilCompleted];
  if(buffer.status!=MTLCommandBufferStatusCompleted)return 4;
  unsigned* values=(unsigned*)output.contents;for(unsigned i=0;i<64;i++)if(values[i]!=i*3+7)return 5;
  puts("OFFLINE_METAL_READBACK_OK");return 0;
}}
'''


def run(h, require_metal=False):
    try:
        status = h.start()
        require(status['toolchain'].get('cmake') and status['toolchain'].get('ninja'), 'install_development_tools.py required')
        h.report['toolchain'] = status['toolchain']
        a, b = h.call('create', count=2, networkClient=False)['instances']
        aid, bid = a['id'], b['id']
        for name, data in [('CMakeLists.txt', CMAKE), ('probe.c', PROBE), ('helper.cpp', HELPER), ('main.cpp', MAIN), ('boundary.c', BOUNDARY)]:
            h.write(aid, name, data)
        h.write(bid, 'peer_canary', b'private peer data')
        versions = h.execute(aid, ['/bin/sh', '-c', 'set -eu; command -v clang clang++ make cmake ninja; cmake --version; ninja --version'])
        h.report['versions'] = versions.decode()
        h.check('controller-pinned development PATH/CC/CXX/SDKROOT available inside ordinary shell')
        for value in (42, 43):
            h.write(aid, 'answer.cpp', f'int answer(){{return {value};}}\n'.encode())
            result = h.cli('exec', aid, '--timeout', '120', '--', '/bin/sh', '-c',
                'set -eu; cmake -S . -B build -G Ninja; cmake --build build; ctest --test-dir build --output-on-failure; ./build/project ./build/helper')
            require(f'RESULT={value}\n'.encode() in result.stdout, 'real rebuilt output, no stale executable')
            (h.output / f'build_{value}.log').write_bytes(result.stdout + result.stderr)
        h.cli('snapshot', aid)
        current = h.call('inspect', instanceID=aid)['instance']
        require(current['physical']['home'] == a['physical']['home'] and current['revisions'] == 1, 'no hidden publication/container replacement')
        require(not current.get('checkpointError'), 'versioned dylib build checkpoint succeeded')
        snapshot = h.call('export', instanceID=aid)['files']
        require(any(f.get('linkTarget') for f in snapshot), 'versioned dylib aliases saved')
        h.check('CMake try_run, Ninja, CTest, helper and versioned custom dylib in one shell; repeat edit/build/run')

        make = h.cli('exec', aid, '--timeout', '120', '--', '/bin/sh', '-c',
            'set -eu; cmake -S . -B make_build -G "Unix Makefiles"; cmake --build make_build; ctest --test-dir make_build --output-on-failure')
        (h.output/'make.log').write_bytes(make.stdout + make.stderr)
        h.check('ordinary CMake Unix Makefiles generator with real make/ar/ranlib')
        h.execute(aid, ['/bin/sh', '-c', 'set -eu; clang probe.c -o "$TMPDIR/probe"; "$TMPDIR/probe"; clang probe.c -o "$HOME/probe"; "$HOME/probe"'])
        h.check('temporary compiler tests and per-instance HOME executables remain sandboxed')

        host_canary = h.output/'host_canary'; host_canary.write_text('private controller data')
        tool = Path(status['toolchain']['ninja']).parent/'installation.json'
        original = tool.read_bytes()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen(1)
            args = [str(host_canary), b['physical']['workspace']+'/peer_canary', str(h.state/'operator_token'), str(tool), str(listener.getsockname()[1])]
            result = h.execute(aid, ['/bin/sh', '-c', 'set -eu; clang boundary.c -o boundary; ./boundary "$@"', 'sh', *args])
            require(result == b'GENERATED_BINARY_BOUNDARIES_OK\n', result)
        require(tool.read_bytes() == original and host_canary.read_text() == 'private controller data', 'outside files unchanged')
        h.check('newly compiled unsigned-entitlement child denies peer/controller/token, tool writes and network')
        h.write(aid, 'bad.c', b'#error intentional_compiler_failure\n')
        failed = h.cli('exec', aid, '--', '/bin/sh', '-c', 'set -eu; clang bad.c -o bad; ./bad', success=False)
        require(failed.returncode != 0 and b'intentional_compiler_failure' in failed.stderr, 'diagnostics and failure propagated')
        require(not h.call('status')['status'].get('recoveryReason'), 'normal compiler failure is not GPU recovery')
        h.write(aid, 'bad.c', PROBE)
        h.execute(aid, ['/bin/sh', '-c', 'set -eu; clang bad.c -o bad; ./bad'])
        h.check('compiler diagnostics, fail-fast and subsequent correction work without special agent protocol')
        h.call('stop', instanceID=aid)
        restored = h.call('restore', instanceID=aid)['instance']['id']
        result = h.execute(restored, ['./build/project', './build/helper'])
        require(result == b'RESULT=43\n', result)
        h.check('snapshot restore preserves helper/dylib and sibling symlink aliases in a fresh container')
        if status['toolchain'].get('metalCompiler') and status['toolchain'].get('metallib'):
            h.write(restored, 'shader.metal', SHADER)
            h.write(restored, 'metal_check.mm', METAL_RUNNER)
            result = h.execute(restored, ['/bin/sh', '-c',
                'set -eu; metal --version; metal -std=metal3.1 -c shader.metal -o shader.air; metallib shader.air -o shader.metallib; '
                'clang++ metal_check.mm -fobjc-arc -framework Foundation -framework Metal -o metal_check; ./metal_check'], 120)
            require(b'OFFLINE_METAL_READBACK_OK\n' in result, result)
            require(h.read(restored, 'shader.metallib')[:4] == b'MTLB', 'real offline metallib container')
            h.report['offlineMetal'] = {'status': 'passed', 'output': result.decode()}
            h.check('offline metal -> air -> metallib -> Objective-C++ runner -> real GPU readback in one shell')
        else:
            h.report['offlineMetal'] = {'status': 'not_installed', 'detail': 'Xcode Metal Toolchain is optional for CPU-only development checks'}
            require(not require_metal, 'install official Metal Toolchain for required offline shader acceptance')
        for iid in (aid, bid, restored):
            if h.call('inspect', instanceID=iid)['instance']['state'] == 'active': h.call('stop', instanceID=iid)
            h.call('delete', instanceID=iid, confirmed=True)
        h.report['result'] = 'passed'
    except Exception as error:
        h.report['result'] = 'failed'; h.report['error'] = repr(error)
        raise
    finally:
        if h.process and h.process.poll() is None:
            h.call('shutdown'); h.process.wait(timeout=30)
        h.report['activeLeaseRemains'] = (h.coord/'active-lease.json').exists()
        (h.output/'report.json').write_text(json.dumps(h.report, indent=2)+'\n')
        for log in h.logs: log.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-metal', action='store_true')
    args = parser.parse_args()
    if os.getuid() == 0: raise SystemExit('do not run as root')
    run(Harness(args.bin_dir, args.output), require_metal=args.require_metal)
