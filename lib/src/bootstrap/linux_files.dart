part of 'bootstrap.dart';

// Bootstrap owns initialization outcomes; the bridge owns platform operations.
class _LinuxFiles {
  final int _directory;
  final NativeIo _io;
  _LinuxFiles(String root, this._io) : _directory = _openRoot(root, _io);

  static int _openRoot(String root, NativeIo io) {
    final call = io.openRoot(root);
    if (!call.succeeded) call.fail('Open root', root);
    return call.value;
  }

  int create(String name) {
    final call = _io.openOutput(_directory, name, OutputMode.exclusive);
    if (!call.succeeded) call.fail('Exclusive create', name);
    return call.value;
  }

  bool exists(String name) {
    final call = _io.observeChild(_directory, name);
    if (call.category == IoCategory.missing) return false;
    if (!call.succeeded) call.fail('Observe residual', name);
    if (call.value != 1)
      throw UnsupportedError('Invalid native entry observation.');
    return true;
  }

  void write(int handle, String content) {
    final bytes = utf8.encode(content);
    _io.withBytes(bytes, (pointer) {
      var offset = 0;
      while (offset < bytes.length) {
        final call = _io.write(handle, pointer + offset, bytes.length - offset);
        if (call.category == IoCategory.interrupted) continue;
        if (!call.succeeded ||
            call.value <= 0 ||
            call.value > bytes.length - offset)
          call.fail('Write', 'startup file');
        offset += call.value;
      }
      final call = _io.flush(handle);
      if (!call.succeeded) call.fail('Flush', 'startup file');
    });
  }

  void close(int handle) {
    final call = _io.close(handle);
    if (!call.succeeded) call.fail('Close', 'startup file');
  }

  void dispose() => close(_directory);
}
