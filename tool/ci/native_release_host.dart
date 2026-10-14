// Actual host and analysis-runtime admission for final native release probes.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;

import 'native_acceptance_capture.dart';

const _targets = {
  'linux-x64': (Abi.linuxX64, 'Linux', 'x86_64', 'linux', 'x64'),
  'macos-arm64': (Abi.macosArm64, 'Darwin', 'arm64', 'darwin', 'arm64'),
  'windows-x64': (Abi.windowsX64, 'Windows', 'AMD64', 'win32', 'x64'),
};

Future<String> _capture(List<String> command) async {
  final temporary = Directory.systemTemp.createTempSync('archway-identity-');
  try {
    final output = File(p.join(temporary.path, 'stdout'));
    final errors = File(p.join(temporary.path, 'stderr'));
    final out = output.openSync(mode: FileMode.write);
    RandomAccessFile? err;
    late final int code;
    try {
      err = errors.openSync(mode: FileMode.write);
      code = await captureAcceptanceProcess(
        command,
        Directory.current.path,
        Platform.environment,
        out,
        err,
        const Duration(seconds: 15),
      );
    } finally {
      try {
        out.closeSync();
      } finally {
        err?.closeSync();
      }
    }
    if (output.lengthSync() > 65536 || errors.lengthSync() > 65536) {
      throw const FormatException('Native identity output exceeds bound');
    }
    if (code != 0) {
      throw ProcessException(
        command.first,
        command.skip(1).toList(),
        utf8.decode(errors.readAsBytesSync(), allowMalformed: true),
        code,
      );
    }
    return utf8.decode(output.readAsBytesSync()).trim();
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

Future<Map<String, Object?>> nativeReleaseHost(
  String target, {
  required bool ciHost,
}) async {
  final expected = _targets[target];
  if (expected == null) throw ArgumentError.value(target, 'target');
  if (Abi.current() != expected.$1) {
    throw UnsupportedError('Wrong native host for $target: ${Abi.current()}');
  }
  if (Platform.isWindows) return _windowsHost(ciHost);
  final observed = <String, Object?>{};
  for (final entry in const {
    'system': '-s',
    'machine': '-m',
    'version': '-v',
    'release': '-r',
  }.entries) {
    observed[entry.key] = await _capture(['/usr/bin/uname', entry.value]);
  }
  if (observed['system'] != expected.$2 || observed['machine'] != expected.$3) {
    throw UnsupportedError('Wrong native host for $target: $observed');
  }
  if (ciHost && Platform.isLinux) {
    final etc = File('/etc/os-release');
    final release = (etc.existsSync() ? etc : File('/usr/lib/os-release'))
        .readAsLinesSync();
    final values = <String, String>{};
    for (final line in release) {
      final match = RegExp(r'^(ID|VERSION_ID)=(.*)$').firstMatch(line);
      if (match == null) continue;
      var value = match[2]!;
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      values[match[1]!] = value;
    }
    final libc = DynamicLibrary.open('libc.so.6');
    final version = libc
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'gnu_get_libc_version',
        )()
        .toDartString();
    if (values['ID'] != 'ubuntu' ||
        values['VERSION_ID'] != '24.04' ||
        version != '2.39') {
      throw UnsupportedError(
        'Wrong actual host: Ubuntu 24.04/glibc 2.39 required',
      );
    }
  } else if (ciHost && Platform.isMacOS) {
    final version = await _capture(['/usr/bin/sw_vers', '-productVersion']);
    if (!version.startsWith('15.')) {
      throw UnsupportedError('Wrong actual host: macOS 15 required');
    }
  }
  return observed;
}

Map<String, Object?> _windowsHost(bool ciHost) {
  // OSVERSIONINFOEXW has a fixed layout. Observe the native machine even
  // when this x64 process runs under Windows ARM64 emulation.
  final version = calloc<Uint8>(284);
  final machines = calloc<Uint16>(2);
  try {
    version.cast<Uint32>().value = 284;
    final status = DynamicLibrary.open('ntdll.dll')
        .lookupFunction<
          Int32 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)
        >('RtlGetVersion')(version);
    if (status != 0) throw OSError('RtlGetVersion failed', status);
    final kernel = DynamicLibrary.open('kernel32.dll');
    final currentProcess = kernel
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'GetCurrentProcess',
        )();
    final observed = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint16>),
          int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint16>)
        >('IsWow64Process2')(currentProcess, machines, machines + 1);
    if (observed == 0) throw const OSError('IsWow64Process2 failed');
    if ((machines + 1).value != 0x8664) {
      throw UnsupportedError('Wrong native host: Windows AMD64 required');
    }
    final major = (version + 4).cast<Uint32>().value;
    final minor = (version + 8).cast<Uint32>().value;
    final build = (version + 12).cast<Uint32>().value;
    final productType = (version + 282).value;
    if (ciHost && (build != 26100 || productType != 3)) {
      throw UnsupportedError(
        'Wrong actual host: Windows Server 2025 build 26100 required',
      );
    }
    final number = '$major.$minor.$build';
    final String release;
    if (major > 10 || (major == 10 && minor > 0)) {
      release = productType == 1 ? 'post11' : 'post2025Server';
    } else if (major == 10) {
      release = productType == 1
          ? (build >= 22000 ? '11' : '10')
          : build >= 26100
          ? '2025Server'
          : build >= 20348
          ? '2022Server'
          : build >= 17763
          ? '2019Server'
          : '2016Server';
    } else {
      release = number;
    }
    return {
      'system': 'Windows',
      'machine': 'AMD64',
      'version': number,
      'release': release,
    };
  } finally {
    calloc.free(machines);
    calloc.free(version);
  }
}

Future<({File executable, List<String> identity})> nativeReleaseNode(
  String target,
) async {
  final expected = _targets[target];
  if (expected == null) throw ArgumentError.value(target, 'target');
  final path = Platform.isWindows
      ? Platform.environment.entries
            .where((entry) => entry.key.toUpperCase() == 'PATH')
            .map((entry) => entry.value)
            .firstOrNull
      : Platform.environment['PATH'];
  if (path == null || path.isEmpty) {
    throw const FormatException('Pinned analysis Node is missing from PATH');
  }
  File? executable;
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    final file = File(
      p.join(directory, Platform.isWindows ? 'node.exe' : 'node'),
    );
    if (file.existsSync() &&
        (Platform.isWindows || posix.access(file.path, posix.X_OK) == 0)) {
      executable = File(file.resolveSymbolicLinksSync());
      break;
    }
  }
  if (executable == null) {
    throw const FormatException('Pinned analysis Node is missing from PATH');
  }
  final value = jsonDecode(
    await _capture([
      executable.path,
      '-p',
      'JSON.stringify([process.version,process.platform,process.arch])',
    ]),
  );
  if (value is! List ||
      value.length != 3 ||
      value[0] != 'v24.21.0' ||
      value[1] != expected.$4 ||
      value[2] != expected.$5) {
    throw const FormatException('Wrong pinned analysis Node');
  }
  return (executable: executable, identity: List<String>.from(value));
}
