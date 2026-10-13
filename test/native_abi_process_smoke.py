"""ABI wire failures observed only through the real compiled CLI entrypoint."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from installation_staging import stage_installation
from native_process_support import native_target, build_library

with tempfile.TemporaryDirectory(prefix='archway-abi-') as temp:
    base = Path(temp).resolve()
    binary = stage_installation(Path(sys.argv[1]), base / 'bundle')
    root = base / 'project'
    root.mkdir()
    (root / 'architecture.yaml').write_text('version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n')
    # Independent ABI oracle: a valid zero-valued root handle, then a Win32
    # conflict. Classification must not depend on POSIX errno 17 or fd > 0.
    source = base / 'bridge.c'
    source.write_text('''
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif
typedef struct { uint64_t value; uint32_t native_error; uint32_t status; } result;
API int32_t archway_io_version(void) { return 2; }
API void *archway_io_alloc(uint64_t size) { return malloc(size); }
API void archway_io_free(void *p) { free(p); }
API result archway_io_open_root(const char *p) { (void)p; return (result){0,0,0}; }
API result archway_io_open_child_directory(uint64_t p, const char *n) { (void)p; (void)n; return (result){0,0,0}; }
API result archway_io_open_output(uint64_t p, const char *n, uint32_t m) { (void)p; (void)n; (void)m; return (result){0,183,131074}; }
API result archway_io_observe_child(uint64_t p, const char *n) { (void)p; (void)n; return (result){1,0,0}; }
API result archway_io_write(uint64_t h, const void *b, uint64_t n) { (void)h; (void)b; return (result){n,0,0}; }
API result archway_io_flush(uint64_t h) { (void)h; return (result){0,0,0}; }
API result archway_io_close(uint64_t h) { (void)h; return (result){0,0,0}; }
API result archway_io_read_alias(const char *p, void *b, uint64_t n) { (void)p; (void)b; (void)n; return (result){0,0,4}; }
''')
    target, library, _ = native_target()
    asset = base / 'bundle/native' / target / library
    original = source.read_text()

    def invoke(wire='0,183,131074', expected='EXPORT_TARGET_EXISTS', message=None, flush='0,0,0', close='0,0,0'):
        text = original.replace('0,183,131074', wire)
        for operation, replacement in [('flush', flush), ('close', close)]:
            text = text.replace(
                'archway_io_' + operation + '(uint64_t h) { (void)h; return (result){0,0,0}',
                'archway_io_' + operation + '(uint64_t h) { (void)h; return (result){' + replacement + '}')
        source.write_text(text)
        build_library(source, asset)
        result = subprocess.run([str(binary), '--root', str(root), 'export', '--format', 'mermaid', '--out', 'out.mmd'], capture_output=True, timeout=10)
        assert result.returncode == 2, result
        assert result.stdout == b'', result
        diagnostic = json.loads(result.stderr)['diagnostics'][-1]
        assert diagnostic['code'] == expected, diagnostic
        if message:
            assert message in diagnostic['message'], diagnostic
        assert not (root / 'out.mmd').exists()

    invoke(message='win32 183')
    invoke('0,3221225506,196614', 'EXPORT_WRITE_FAILED', 'ntstatus 3221225506')
    for wire in [
        '0,0,7',          # Unknown category.
        '0,1,262150',     # Unknown native domain.
        '0,1,65536',      # Success cannot carry an error/domain.
        '1,183,131074',   # A failed open cannot transfer a handle.
        '0,183,2',       # Domain none cannot carry native error bits.
        '0,0,65542',     # Native failure domains require an actual native code.
    ]:
        invoke(wire, 'EXPORT_WRITE_FAILED', 'Invalid native I/O result encoding')
    invoke('1,0,0', 'EXPORT_WRITE_FAILED', 'Invalid native flush result', flush='1,0,0')
    invoke('1,0,0', 'EXPORT_WRITE_FAILED', 'Invalid native close result', close='1,0,0')
    # Independent buffer-exhaustion oracle on every host, including Windows
    # where a real reparse payload has a different platform size ceiling.
    alias = base / 'root-alias'
    alias.symlink_to(root, target_is_directory=True)
    result = subprocess.run([str(binary), '--root', str(alias), 'validate'],
                            capture_output=True, timeout=10)
    assert result.returncode == 2 and result.stderr == b'', result
    diagnostic = json.loads(result.stdout)['diagnostics'][0]
    assert diagnostic['code'] == 'ROOT_ACCESS_FAILED', diagnostic
    assert 'Symbolic link target exceeds limit' in diagnostic['message'], diagnostic
print('11 ABI v2 encoding/category/domain/buffer CLI cases passed')
