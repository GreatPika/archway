import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ffi';
import 'dart:io';

final class _NativeResult extends Struct {
  @Uint64()
  external int value;
  @Uint32()
  external int nativeError;
  @Uint32()
  external int status;
}

enum IoCategory {
  success,
  missing,
  exists,
  interrupted,
  bufferTooSmall,
  unsupportedEntry,
  other,
}

enum IoDomain { none, posix, win32, ntstatus }

enum OutputMode { exclusive, overwrite }

class IoResult {
  final int value;
  final int nativeError;
  final IoCategory category;
  final IoDomain domain;
  const IoResult(this.value, this.nativeError, this.category, this.domain);
  bool get succeeded => category == IoCategory.success;
  Never fail(String operation, String path) =>
      throw NativeIoException(operation, path, this);
}

/// Internal carrier; public diagnostics retain FileSystemException formatting.
class NativeIoException extends FileSystemException {
  final IoCategory category;
  final IoDomain domain;
  NativeIoException(String operation, String path, IoResult result)
    : category = result.category,
      domain = result.domain,
      super(
        operation,
        path,
        OSError(
          '${result.domain.name} ${result.nativeError}',
          result.nativeError,
        ),
      );
}

/// Single private owner of the semantic ABI and its matched native allocator.
class NativeIo {
  static Future<NativeIo>? _loaded;
  static Future<NativeIo> load() => _loaded ??= _load();
  static Future<NativeIo> _load() async => (await prepareLoader())();

  /// Resolve the trusted asset without loading until an operation needs it.
  static Future<NativeIo Function()> prepareLoader() async {
    if (!(Platform.isLinux && Abi.current() == Abi.linuxX64) &&
        !(Platform.isWindows && Abi.current() == Abi.windowsX64) &&
        !(Platform.isMacOS && Abi.current() == Abi.macosArm64)) {
      throw UnsupportedError(
        'Native file writes require Linux x64, Windows x64, or macOS arm64.',
      );
    }
    if (sizeOf<_NativeResult>() != 16) {
      throw UnsupportedError('Unsupported native I/O result layout.');
    }
    return () {
      try {
        if (_version() != 2) {
          throw UnsupportedError('Unsupported native I/O ABI.');
        }
        // Resolve the complete ABI before allocating or performing a write.
        // A partially present library must fail before it can own any resources.
        final symbols = <Pointer>[
          Native.addressOf<
            NativeFunction<_NativeResult Function(Pointer<Uint8>)>
          >(_openRoot),
          Native.addressOf<
            NativeFunction<_NativeResult Function(Uint64, Pointer<Uint8>)>
          >(_openChildDirectory),
          Native.addressOf<
            NativeFunction<
              _NativeResult Function(Uint64, Pointer<Uint8>, Uint32)
            >
          >(_openOutput),
          Native.addressOf<
            NativeFunction<_NativeResult Function(Uint64, Pointer<Uint8>)>
          >(_observeChild),
          Native.addressOf<
            NativeFunction<
              _NativeResult Function(Uint64, Pointer<Uint8>, Uint64)
            >
          >(_write),
          Native.addressOf<NativeFunction<_NativeResult Function(Uint64)>>(
            _flush,
          ),
          Native.addressOf<NativeFunction<_NativeResult Function(Uint64)>>(
            _close,
          ),
          Native.addressOf<
            NativeFunction<
              _NativeResult Function(Pointer<Uint8>, Pointer<Uint8>, Uint64)
            >
          >(_readAlias),
          Native.addressOf<NativeFunction<Pointer<Void> Function(Uint64)>>(
            _alloc,
          ),
          Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(_free),
        ];
        if (symbols.any((symbol) => symbol == nullptr)) {
          throw UnsupportedError('Incomplete native I/O ABI.');
        }
        return NativeIo._();
      } on ArgumentError catch (error) {
        throw UnsupportedError(
          'Native I/O asset unavailable or incompatible: $error',
        );
      }
    };
  }

  NativeIo._();

  @Native<Int32 Function()>(
    symbol: 'archway_io_version',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static int _version();

  @Native<_NativeResult Function(Pointer<Uint8>)>(
    symbol: 'archway_io_open_root',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _openRoot(Pointer<Uint8> path);

  @Native<_NativeResult Function(Uint64, Pointer<Uint8>)>(
    symbol: 'archway_io_open_child_directory',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _openChildDirectory(
    int parent,
    Pointer<Uint8> name,
  );

  @Native<_NativeResult Function(Uint64, Pointer<Uint8>, Uint32)>(
    symbol: 'archway_io_open_output',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _openOutput(
    int parent,
    Pointer<Uint8> name,
    int mode,
  );

  @Native<_NativeResult Function(Uint64, Pointer<Uint8>)>(
    symbol: 'archway_io_observe_child',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _observeChild(int parent, Pointer<Uint8> name);

  @Native<_NativeResult Function(Uint64, Pointer<Uint8>, Uint64)>(
    symbol: 'archway_io_write',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _write(
    int handle,
    Pointer<Uint8> bytes,
    int length,
  );

  @Native<_NativeResult Function(Uint64)>(
    symbol: 'archway_io_flush',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _flush(int handle);

  @Native<_NativeResult Function(Uint64)>(
    symbol: 'archway_io_close',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _close(int handle);

  @Native<_NativeResult Function(Pointer<Uint8>, Pointer<Uint8>, Uint64)>(
    symbol: 'archway_io_read_alias',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static _NativeResult _readAlias(
    Pointer<Uint8> path,
    Pointer<Uint8> bytes,
    int capacity,
  );

  @Native<Pointer<Void> Function(Uint64)>(
    symbol: 'archway_io_alloc',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static Pointer<Void> _alloc(int size);

  @Native<Void Function(Pointer<Void>)>(
    symbol: 'archway_io_free',
    assetId: 'package:archway/src/native/native_io.dart',
  )
  external static void _free(Pointer<Void> pointer);

  IoResult openRoot(String root) =>
      _withPath(root, (p) => _decode(_openRoot(p)));
  IoResult openChildDirectory(int parent, String name) =>
      _withPath(name, (p) => _decode(_openChildDirectory(parent, p)));
  IoResult openOutput(int parent, String name, OutputMode mode) =>
      _withPath(name, (p) => _decode(_openOutput(parent, p, mode.index)));
  IoResult observeChild(int parent, String name) =>
      _withPath(name, (p) => _decode(_observeChild(parent, p)));
  IoResult write(int handle, Pointer<Uint8> bytes, int length) =>
      _decode(_write(handle, bytes, length));
  IoResult flush(int handle) {
    final result = _decode(_flush(handle));
    if (result.succeeded && result.value != 0)
      throw UnsupportedError('Invalid native flush result.');
    return result;
  }

  IoResult close(int handle) {
    final result = _decode(_close(handle));
    if (result.succeeded && result.value != 0)
      throw UnsupportedError('Invalid native close result.');
    return result;
  }

  T _withPath<T>(String path, T Function(Pointer<Uint8>) action) {
    if (path.contains('\u0000'))
      throw FileSystemException('Embedded NUL in native path', path);
    return withBytes([...utf8.encode(path), 0], action);
  }

  T withBytes<T>(List<int> bytes, T Function(Pointer<Uint8>) action) {
    final pointer = _allocate(bytes.isEmpty ? 1 : bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      return action(pointer);
    } finally {
      _free(pointer.cast());
    }
  }

  Pointer<Uint8> _allocate(int size) {
    final pointer = _alloc(size).cast<Uint8>();
    if (pointer == nullptr)
      throw const FileSystemException('Native allocation failed');
    return pointer;
  }

  Uint8List readLinkBytes(String path) => _withPath(path, (name) {
    for (var size = 256; size <= 1048576; size *= 2) {
      final bytes = _allocate(size);
      try {
        final result = _decode(_readAlias(name, bytes, size));
        if (result.category == IoCategory.bufferTooSmall) continue;
        if (!result.succeeded) result.fail('Read symbolic link', path);
        if (result.value < 0 || result.value >= size)
          throw UnsupportedError('Invalid native alias byte count.');
        return Uint8List.fromList(bytes.asTypedList(result.value));
      } finally {
        _free(bytes.cast());
      }
    }
    throw FileSystemException('Symbolic link target exceeds limit', path);
  });

  static IoResult _decode(_NativeResult result) {
    // Copy captured bits before the existing private post-call fault hook.
    final value = result.value;
    final error = result.nativeError;
    final status = result.status;
    (Zone.current[#archwayNativeAfterCall] as void Function()?)?.call();
    final category = status & 0xffff;
    final domain = status >> 16;
    if (category >= IoCategory.values.length ||
        domain >= IoDomain.values.length ||
        (category == 0 && (domain != 0 || error != 0)) ||
        (category != 0 && value != 0) ||
        (domain == 0 ? error != 0 : error == 0)) {
      throw UnsupportedError('Invalid native I/O result encoding.');
    }
    return IoResult(
      value,
      error,
      IoCategory.values[category],
      IoDomain.values[domain],
    );
  }
}
