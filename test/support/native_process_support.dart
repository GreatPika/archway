// Host-native fixture compilers and bounded, reaped process invocations.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_job.dart';
import 'windows_process.dart';
import 'windows_process_pipes.dart';

({String target, String library, String source}) nativeTarget() =>
    switch (Abi.current()) {
      Abi.linuxX64 => (
        target: 'linux-x64',
        library: 'libarchway_io.so',
        source: 'linux_io.c',
      ),
      Abi.macosArm64 => (
        target: 'macos-arm64',
        library: 'libarchway_io.dylib',
        source: 'macos_io.c',
      ),
      Abi.windowsX64 => (
        target: 'windows-x64',
        library: 'archway_io.dll',
        source: 'windows_io.c',
      ),
      final host => throw UnsupportedError(
        'Unsupported native probe host: $host',
      ),
    };

typedef NativeProcessResult = ({
  int exitCode,
  List<int> stdout,
  List<int> stderr,
});

Future<NativeProcessResult> runNativeProcess(
  List<String> command, {
  required Duration timeout,
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  if (Platform.isWindows) {
    WindowsProcessPipes? pipes;
    WindowsJob? job;
    WindowsSuspendedProcess? child;
    try {
      pipes = WindowsProcessPipes();
      job = WindowsJob();
      child = job.spawn(
        command,
        output: pipes,
        workingDirectory: workingDirectory,
        environment: environment,
      );
      final result = await pipes.communicate(() => child!.exitCode, timeout);
      return (
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    } finally {
      try {
        job?.close();
      } finally {
        try {
          child?.close();
        } finally {
          pipes?.close();
        }
      }
    }
  }
  final child = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: environment == null,
  );
  final output = <int>[], errors = <int>[];
  final outputDone = Completer<void>(), errorsDone = Completer<void>();
  StreamSubscription<List<int>> capture(
    Stream<List<int>> stream,
    List<int> bytes,
    Completer<void> done,
  ) => stream.listen(
    bytes.addAll,
    onDone: done.complete,
    onError: done.completeError,
  );
  final outputSubscription = capture(child.stdout, output, outputDone);
  final errorSubscription = capture(child.stderr, errors, errorsDone);
  var exited = false;
  final completion = child.exitCode.then((code) {
    exited = true;
    return code;
  });
  try {
    final results = await Future.wait<Object?>([
      completion,
      child.stdin.close(),
      outputDone.future,
      errorsDone.future,
    ]).timeout(timeout);
    return (exitCode: results.first as int, stdout: output, stderr: errors);
  } finally {
    try {
      if (!exited) {
        child.kill(ProcessSignal.sigkill);
        await completion.timeout(const Duration(seconds: 5));
      }
    } finally {
      try {
        await outputSubscription.cancel();
      } finally {
        await errorSubscription.cancel();
      }
    }
  }
}

Future<NativeProcessResult> _checked(
  List<String> command, {
  Duration timeout = const Duration(seconds: 60),
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await runNativeProcess(
    command,
    timeout: timeout,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Native fixture command failed ($command): ${result.exitCode}\n'
      '${utf8.decode(result.stdout, allowMalformed: true)}\n'
      '${utf8.decode(result.stderr, allowMalformed: true)}',
    );
  }
  return result;
}

Future<void> buildNativeLibrary(File source, File destination) async {
  final repository = File.fromUri(Platform.script).parent.parent;
  final include = p.join(repository.path, 'native');
  final target = nativeTarget().target;
  if (target == 'windows-x64') {
    return _buildWindowsLibrary(source, destination, include);
  }
  final command = target == 'macos-arm64'
      ? [
          'xcrun',
          '--sdk',
          'macosx',
          'clang',
          '-arch',
          'arm64',
          '-mmacosx-version-min=15.0',
          '-std=c11',
          '-O2',
          '-Wall',
          '-Wextra',
          '-Werror',
          '-dynamiclib',
          '-Wl,-install_name,@rpath/libarchway_io.dylib',
        ]
      : ['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC'];
  await _checked([
    ...command,
    '-I',
    include,
    source.path,
    '-o',
    destination.path,
  ]);
}

Future<void> _buildWindowsLibrary(
  File source,
  File destination,
  String include,
) async {
  String? value(String name) {
    for (final entry in Platform.environment.entries) {
      if (entry.key.toUpperCase() == name.toUpperCase()) return entry.value;
    }
    return null;
  }

  final programFiles = value('ProgramFiles(x86)');
  if (programFiles == null) throw StateError('ProgramFiles(x86) is missing');
  final installation = await visualStudioInstallation(
    p.join(programFiles, 'Microsoft Visual Studio', 'Installer', 'vswhere.exe'),
  );
  final msvc = p.join(installation, 'VC', 'Tools', 'MSVC', '14.44.35207');
  final sdk = p.join(programFiles, 'Windows Kits', '10');
  const version = '10.0.26100.0';
  final binary = p.join(msvc, 'bin', 'Hostx64', 'x64');
  final includes = [
    p.join(msvc, 'include'),
    for (final name in ['ucrt', 'shared', 'um'])
      p.join(sdk, 'Include', version, name),
  ];
  final libraries = [
    p.join(msvc, 'lib', 'x64'),
    for (final name in ['ucrt', 'um']) p.join(sdk, 'Lib', version, name, 'x64'),
  ];
  for (final path in [
    p.join(binary, 'cl.exe'),
    p.join(binary, 'link.exe'),
    ...includes,
    ...libraries,
  ]) {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      throw StateError('Pinned Windows native fixture input is missing: $path');
    }
  }
  final environment = <String, String>{
    for (final entry in Platform.environment.entries)
      if (!{
        'CL',
        '_CL_',
        'LINK',
        '_LINK_',
        'INCLUDE',
        'LIB',
        'PATH',
      }.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
    'PATH': '$binary;${value('PATH') ?? ''}',
    'INCLUDE': includes.join(';'),
    'LIB': libraries.join(';'),
  };
  final work = Directory.systemTemp.createTempSync('archway-native-compiler-');
  try {
    await _checked(
      [
        p.join(binary, 'cl.exe'),
        '/nologo',
        '/std:c11',
        '/O2',
        '/W4',
        '/WX',
        '/MT',
        '/LD',
        '/TC',
        '/I$include',
        source.path,
        '/Fo${p.join(work.path, 'fixture.obj')}',
        '/Fe${destination.path}',
        '/link',
        '/MACHINE:X64',
        '/DYNAMICBASE',
        '/NXCOMPAT',
        '/INCREMENTAL:NO',
        '/IMPLIB:${p.join(work.path, 'fixture.lib')}',
        'ntdll.lib',
        'kernel32.lib',
      ],
      environment: environment,
      workingDirectory: work.path,
    );
  } finally {
    work.deleteSync(recursive: true);
  }
}

// Narrow discovery seam: raw stdout must match vswhere's requested encoding.
Future<String> visualStudioInstallation(
  String executable, {
  Future<NativeProcessResult> Function(
        List<String>, {
        required Duration timeout,
      })
      run =
      _checked,
}) async {
  final discovery = await run([
    executable,
    '-latest',
    '-products',
    '*',
    '-requires',
    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '-property',
    'installationPath',
    '-utf8', // Redirected output otherwise uses the console code page.
  ], timeout: const Duration(seconds: 15));
  final installation = utf8.decode(discovery.stdout).trim();
  if (installation.isEmpty) {
    throw StateError('Installed Visual Studio x64 tools are missing');
  }
  return installation;
}
