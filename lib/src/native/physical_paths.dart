import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_io.dart';

/// Private filesystem reader shared by root selection and input observation.
/// Ordinary routes never load the native library. Raw link text is decoded
/// strictly before dart:io is allowed to canonicalize any linked pathname.
class PhysicalPaths {
  static NativeIo? _io;
  static NativeIo Function()? _loader;
  static Future<void> prepare() async {
    if (_loader != null) return;
    try {
      _loader = await NativeIo.prepareLoader();
    } catch (error) {
      _loader = () => throw error;
    }
  }

  static String fromFileUri(Uri uri) {
    if (!Platform.isWindows) {
      // Uri.toFilePath decodes each segment with BOM stripping. Preserve path
      // scalars by decoding the entire escaped path after an ASCII prefix.
      return Uri.decodeComponent('x${uri.path}').substring(1);
    }
    // Retain the SDK's Windows URI/character validation, but not its decoded
    // segments: decoding each segment strips a leading literal U+FEFF.
    uri.toFilePath();
    var path = Uri.decodeComponent('x${uri.path}')
        .substring(1)
        .replaceAll('/', r'\');
    if (uri.host.isNotEmpty) {
      path = '\\\\${uri.host}$path';
    } else if (path.length >= 3 && path[0] == r'\' && path[2] == ':') {
      path = path.substring(1); // /D:/... is a drive path, not a rooted path.
    }
    if (File(path).uri != uri) {
      throw FileSystemException(
        'File URI cannot be decoded losslessly',
        uri.toString(),
      );
    }
    return path;
  }

  static String readLinkTarget(String link) {
    try {
      // An ASCII prefix prevents BOM stripping; filesystem text stays exact.
      return utf8
          .decode([0x78, ...(_io ??= _loader!()).readLinkBytes(link)])
          .substring(1);
    } catch (error) {
      throw FileSystemException(
        'Cannot read a safe symbolic-link target: $error',
        link,
      );
    }
  }

  static Future<String> canonical(String native) async {
    await prepare();
    trace(native);
    return File(native).resolveSymbolicLinks();
  }

  static ({String path, List<Map<String, String>> hops}) trace(String native) {
    final aliases = <Map<String, String>>[];
    final active = <String>{};
    var hops = 0;
    String walk(String path) {
      var current = p.rootPrefix(path);
      for (final segment in p.split(path).skip(1)) {
        if (segment == '.') continue;
        if (segment == '..') {
          current = p.dirname(current);
          continue;
        }
        current = p.join(current, segment);
        if (FileSystemEntity.typeSync(current, followLinks: false) !=
            FileSystemEntityType.link)
          continue;
        if (++hops > 40 || !active.add(current)) {
          throw FileSystemException(
            'Cannot verify cyclic alias chain',
            current,
          );
        }
        final link = current;
        final target = readLinkTarget(link);
        aliases.add({
          'observed_uri': File(link).uri.toString(),
          'target': target,
        });
        final expanded = p.isAbsolute(target)
            ? target
            : '${p.dirname(link)}${p.separator}$target';
        current = walk(expanded);
        // Check the original route: missing/../exists and file/../exists are
        // invalid kernel walks even if lexical collapse ends at a real entry.
        if (FileSystemEntity.typeSync(expanded) ==
            FileSystemEntityType.notFound) {
          throw FileSystemException('Broken symbolic link', link);
        }
        active.remove(link);
      }
      return current;
    }

    final result = walk(
      p.isAbsolute(native)
          ? native
          : '${Directory.current.path}${p.separator}$native',
    );
    return (path: result, hops: aliases);
  }
}
