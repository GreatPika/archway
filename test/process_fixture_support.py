"""Native executable fixtures: no shell launchers or executable-name disguises."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
from urllib.parse import urlsplit
from urllib.request import url2pathname


def file_uri_path(value, *, decoder=url2pathname):
    uri = urlsplit(value)
    if (uri.scheme != 'file' or not uri.path.startswith('/') or uri.query or uri.fragment
            or '@' in uri.netloc or ':' in uri.netloc):
        raise ValueError('Expected an absolute package file URI')
    path = uri.path if uri.netloc in ('', 'localhost') else '//' + uri.netloc + uri.path
    # The platform decoder handles drive/UNC syntax and decodes escapes once.
    return decoder(path)


def dart_executable(sdk, *, windows=None):
    if windows is None:
        windows = os.name == 'nt'
    return Path(sdk) / 'bin' / ('dart.exe' if windows else 'dart')


def dart_string(value):
    # Base64 avoids Dart interpolation and host-specific path escaping.
    encoded = base64.b64encode(str(value).encode('utf-8')).decode('ascii')
    return f"utf8.decode(base64Decode('{encoded}'))"


def compile_runtime_tripwire(sdk, destination, marker, *, delegate=None):
    """Build a real target executable; log each query and optionally forward it.

    Only test preparation invokes the compiler. The inspected project never
    supplies code to this build or to the actual acceptance invocation.
    """
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    body = 'exitCode = 99;'
    if delegate is not None:
        body = f'''
  final result = Process.runSync({dart_string(delegate)}, args);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  exitCode = result.exitCode;
'''
    source = f'''import 'dart:convert';
import 'dart:io';
void main(List<String> args) {{
  File({dart_string(marker)}).writeAsStringSync('query\\n', mode: FileMode.append);
  {body}
}}
'''
    with tempfile.TemporaryDirectory(prefix='archway-tripwire-') as temp:
        program = Path(temp) / 'tripwire.dart'
        program.write_text(source, encoding='utf-8')
        subprocess.run([str(dart_executable(sdk)), '--suppress-analytics', 'compile', 'exe', str(program),
                        '-o', str(destination)], check=True, capture_output=True,
                       timeout=90)
    assert destination.is_file(), f'Compiler did not create {destination}'
