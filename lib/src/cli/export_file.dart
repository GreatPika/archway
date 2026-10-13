part of 'cli.dart';

// The opened output handle is also the handle validated and written: no
// create/reopen gap can redirect a write. Platform certification is separate.
Future<void> _writeExport(
  String root,
  String filename,
  String content,
  bool overwrite,
) async {
  _LinuxExport.write(await NativeIo.load(), root, filename, content, overwrite);
}

class _LinuxExport {
  static void write(
    NativeIo io,
    String root,
    String filename,
    String content,
    bool overwrite,
  ) {
    final components = filename.split('/');
    final directories = <int>[];
    try {
      final openedRoot = io.openRoot(root);
      if (!openedRoot.succeeded) openedRoot.fail('Open output root', root);
      var parent = openedRoot.value;
      directories.add(parent);
      for (final component in components.take(components.length - 1)) {
        final call = io.openChildDirectory(parent, component);
        if (!call.succeeded) call.fail('Open output directory', component);
        parent = call.value;
        directories.add(parent);
      }
      final opened = io.openOutput(
        parent,
        components.last,
        overwrite ? OutputMode.overwrite : OutputMode.exclusive,
      );
      if (!opened.succeeded) opened.fail('Open output path', filename);
      final handle = opened.value;
      try {
        final bytes = utf8.encode(content);
        io.withBytes(bytes, (buffer) {
          var offset = 0;
          while (offset < bytes.length) {
            final call = io.write(
              handle,
              buffer + offset,
              bytes.length - offset,
            );
            if (call.category == IoCategory.interrupted) continue;
            if (!call.succeeded ||
                call.value <= 0 ||
                call.value > bytes.length - offset)
              call.fail('Write output', filename);
            offset += call.value;
          }
          final flushed = io.flush(handle);
          if (!flushed.succeeded) flushed.fail('Flush output', filename);
        });
      } finally {
        final closed = io.close(handle);
        if (!closed.succeeded) closed.fail('Close output', filename);
      }
    } finally {
      // Consume every directory handle, including when output close fails.
      for (final directory in directories.reversed) {
        io.close(directory);
      }
    }
  }
}
