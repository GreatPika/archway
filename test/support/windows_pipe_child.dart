// AOT writer for native pipe completion, inheritance and timeout controls.
import 'dart:ffi';
import 'dart:io';

Future<void> awaitMarker(String path) async {
  final elapsed = Stopwatch()..start();
  while (!File(path).existsSync()) {
    if (elapsed.elapsed >= const Duration(seconds: 10)) {
      throw StateError('Missing pipe fixture barrier: $path');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> awaitParentExit(int parent, String marker) async {
  final api = DynamicLibrary.open('kernel32.dll');
  final error = api.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final open = api
      .lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)
      >('OpenProcess');
  final wait = api
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('WaitForSingleObject');
  final close = api
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  final handle = open(0x00100000, 0, parent);
  if (handle == nullptr) throw OSError('OpenProcess parent', error());
  try {
    File('$marker.attached').createSync();
    if (wait(handle, 10000) != 0)
      throw StateError('Parent exit was not confirmed');
    File('$marker.parent-exited').createSync();
  } finally {
    if (close(handle) == 0) throw OSError('CloseHandle parent', error());
  }
  await awaitMarker('$marker.release');
}

Future<void> main(List<String> arguments) async {
  final mode = arguments[0];
  if (mode == 'late') {
    await Process.start(Platform.resolvedExecutable, [
      'delayed',
      '$pid',
      arguments[1],
    ], mode: ProcessStartMode.inheritStdio);
    await awaitMarker('${arguments[1]}.attached');
    exit(0); // Descendant deliberately retains the two output handles.
  }
  if (mode == 'payload') {
    final set = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('SetEvent');
    set(Pointer<Void>.fromAddress(int.parse(arguments[1])));
    stdout.add(List<int>.filled(100000, 97));
    stderr.add(List<int>.filled(70000, 98));
  } else {
    if (mode == 'delayed') {
      await awaitParentExit(int.parse(arguments[1]), arguments[2]);
    }
    stdout.write('out');
    stderr.write('err');
  }
  await Future.wait([stdout.flush(), stderr.flush()]);
  if (mode == 'timeout') {
    File(arguments[1]).writeAsStringSync('ready');
    await Future<void>.delayed(const Duration(seconds: 60));
  }
}
