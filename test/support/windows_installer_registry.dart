// Developer-only HKCU state for the disposable Windows installer lifecycle.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Opaque raw bytes let an original Path survive even an unexpected value type.
final class WindowsRegistryValue {
  WindowsRegistryValue.raw(this.type, List<int> bytes)
    : _bytes = Uint8List.fromList(bytes);

  factory WindowsRegistryValue.string(String value, {int type = 1}) {
    final bytes = ByteData((value.length + 1) * 2);
    for (var i = 0; i < value.length; i++) {
      bytes.setUint16(i * 2, value.codeUnitAt(i), Endian.little);
    }
    final result = WindowsRegistryValue.raw(type, bytes.buffer.asUint8List());
    result.stringValue; // Reject embedded NUL, invalid UTF-16 and non-string type.
    return result;
  }

  final int type;
  final Uint8List _bytes;

  String get stringValue {
    if ((type != 1 && type != 2) || _bytes.length.isOdd) {
      throw const FormatException(
        'Invalid registry string type or byte length',
      );
    }
    final bytes = ByteData.sublistView(_bytes);
    final units = [
      for (var i = 0; i < _bytes.length; i += 2)
        bytes.getUint16(i, Endian.little),
    ];
    if (units.isNotEmpty && units.last == 0) units.removeLast();
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit == 0 || (unit >= 0xdc00 && unit <= 0xdfff)) {
        throw const FormatException('Invalid registry string encoding');
      }
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
          throw const FormatException('Invalid registry string encoding');
        }
      }
    }
    return String.fromCharCodes(units);
  }

  @override
  String toString() => 'WindowsRegistryValue(<private>)';

  @override
  bool operator ==(Object other) {
    if (other is! WindowsRegistryValue ||
        type != other.type ||
        _bytes.length != other._bytes.length)
      return false;
    for (var i = 0; i < _bytes.length; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(type, Object.hashAll(_bytes));
}

/// A non-null instance means the owner key exists, even with both values absent.
final class WindowsInstallerOwner {
  WindowsInstallerOwner({this.root, this.pathToken}) {
    root?.stringValue;
    pathToken?.stringValue;
  }
  final WindowsRegistryValue? root;
  final WindowsRegistryValue? pathToken;
}

/// Read Path before the first mutation. Keep that opaque value for restoration;
/// only decode controlled synthetic Path values. Null means absent Path/key.
abstract interface class WindowsInstallerRegistry {
  WindowsRegistryValue? readPath();
  void writePath(WindowsRegistryValue? value);
  WindowsInstallerOwner? readOwner();
}

final class NativeWindowsInstallerRegistry implements WindowsInstallerRegistry {
  NativeWindowsInstallerRegistry() {
    if (!Platform.isWindows || Abi.current() != Abi.windowsX64) {
      throw UnsupportedError('Installer registry requires native Windows x64');
    }
    _api = _RegistryApi(); // The ABI guard precedes library/key access.
  }

  late final _RegistryApi _api;
  static final _hkcu = Pointer<Void>.fromAddress(-2147483647);
  static const _environment = 'Environment';
  static const _owner = r'Software\Archway\Installer';
  static const _limit = 1024 * 1024;

  @override
  WindowsRegistryValue? readPath() => _withKey<WindowsRegistryValue?>(
    _environment,
    1,
    false,
    (key) => _read(key, 'Path'),
  );

  @override
  WindowsInstallerOwner? readOwner() => _withKey(
    _owner,
    1,
    false,
    (key) => WindowsInstallerOwner(
      root: _read(key, 'Root'),
      pathToken: _read(key, 'PathToken'),
    ),
  );

  @override
  void writePath(WindowsRegistryValue? value) {
    if (value != null && value._bytes.length > _limit) {
      throw const FormatException('Registry value exceeds fixture limit');
    }
    // Restoring absence must not create a previously absent Environment key.
    _withKey(
      _environment,
      2,
      value != null,
      (key) => using((arena) {
        final name = 'Path'.toNativeUtf16(allocator: arena);
        if (value == null) {
          final status = _api.delete(key, name);
          if (status != 2) _check(status, 'RegDeleteValueW Path');
        } else {
          final bytes = arena<Uint8>(value._bytes.length + 1);
          bytes.asTypedList(value._bytes.length).setAll(0, value._bytes);
          _check(
            _api.set(key, name, 0, value.type, bytes, value._bytes.length),
            'RegSetValueExW Path',
          );
        }
      }),
    );
  }

  T? _withKey<T>(
    String path,
    int access,
    bool create,
    T Function(Pointer<Void>) body,
  ) => using((arena) {
    final output = arena<Pointer<Void>>();
    final name = path.toNativeUtf16(allocator: arena);
    final status = create
        ? _api.create(
            _hkcu,
            name,
            0,
            nullptr,
            0,
            access,
            nullptr,
            output,
            nullptr,
          )
        : _api.open(_hkcu, name, 0, access, output);
    if (!create && status == 2) return null;
    _check(status, create ? 'RegCreateKeyExW' : 'RegOpenKeyExW');
    Object? primary;
    try {
      return body(output.value);
    } catch (error) {
      primary = error;
      rethrow;
    } finally {
      // Close exactly once, including malformed values and failed queries.
      final status = _api.close(output.value);
      if (status != 0) {
        if (primary == null) _check(status, 'RegCloseKey');
        stderr.writeln(
          'RegCloseKey failed (LSTATUS $status) after registry failure',
        );
      }
    }
  });

  WindowsRegistryValue? _read(Pointer<Void> key, String name) => using((arena) {
    final nativeName = name.toNativeUtf16(allocator: arena);
    final type = arena<Uint32>();
    final size = arena<Uint32>();
    var capacity = 256;
    for (var attempt = 0; attempt < 8; attempt++) {
      final bytes = calloc<Uint8>(capacity);
      try {
        size.value = capacity;
        final status = _api.query(key, nativeName, nullptr, type, bytes, size);
        if (status == 2) return null;
        if (status == 234) {
          // ERROR_MORE_DATA: returned bytes are undefined.
          capacity = size.value > capacity * 2 ? size.value : capacity * 2;
          if (capacity > _limit) break;
          continue;
        }
        _check(status, 'RegQueryValueExW $name');
        if (size.value > capacity) {
          throw const FormatException('Invalid registry query byte length');
        }
        return WindowsRegistryValue.raw(
          type.value,
          bytes.asTypedList(size.value),
        );
      } finally {
        calloc.free(bytes);
      }
    }
    throw const FormatException('Registry query exceeded bounded growth');
  });
}

void _check(int status, String operation) {
  if (status != 0) {
    throw FileSystemException(
      operation,
      '',
      OSError('Win32 registry LSTATUS', status),
    );
  }
}

final class _RegistryApi {
  _RegistryApi() {
    // Resolve every operation before a key can be opened and need closing.
    open;
    create;
    query;
    set;
    delete;
    close;
  }

  final _library = DynamicLibrary.open('advapi32.dll');
  late final open = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Pointer<Void>>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf16>,
          int,
          int,
          Pointer<Pointer<Void>>,
        )
      >('RegOpenKeyExW');
  late final create = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf16>,
          int,
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          Pointer<Pointer<Void>>,
          Pointer<Uint32>,
        )
      >('RegCreateKeyExW');
  late final query = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint8>,
          Pointer<Uint32>,
        )
      >('RegQueryValueExW');
  late final set = _library
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Uint8>,
          Uint32,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Utf16>,
          int,
          int,
          Pointer<Uint8>,
          int,
        )
      >('RegSetValueExW');
  late final delete = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Utf16>),
        int Function(Pointer<Void>, Pointer<Utf16>)
      >('RegDeleteValueW');
  late final close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('RegCloseKey');
}
