// Private pinned-payload HTTPS transport. No credentials or runtime URL option.
import 'dart:async';
import 'dart:io';

import '../release/archive_input.dart';

const _downloadTimeout = Duration(minutes: 2);

/// Owns and closes [client]. The optional client and tighter timeout are private
/// fixture seams; the installed launcher uses the default HTTPS client/budget.
/// A failed transfer removes only the exclusively created destination file.
Future<void> downloadNativeArchive(
  Uri uri,
  File destination,
  int expectedBytes, {
  HttpClient? client,
  Duration timeout = _downloadTimeout,
}) async {
  void checkUrl(Uri value) {
    if (value.scheme != 'https' ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasFragment) {
      throw const FormatException(
        'Native download requires an unambiguous HTTPS URL',
      );
    }
  }

  final connection = client ?? HttpClient();
  final elapsed = Stopwatch()..start();
  var expired = false, created = false, complete = false;
  Timer? timer;
  Duration remaining() {
    final value = timeout - elapsed.elapsed;
    if (value <= Duration.zero)
      throw TimeoutException('Native download timed out');
    return value;
  }

  RandomAccessFile? output;
  try {
    if (expectedBytes < 1 ||
        expectedBytes > maxArchiveBytes ||
        timeout <= Duration.zero ||
        timeout > _downloadTimeout) {
      throw const FormatException('Invalid native download bound');
    }
    checkUrl(uri);
    destination = destination.absolute;
    if (await destination.parent.resolveSymbolicLinks() !=
            destination.parent.path ||
        await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const FormatException(
        'Native download destination must be new and canonical',
      );
    }
    connection.autoUncompress = false;
    connection.connectionTimeout = timeout;
    timer = Timer(timeout, () {
      expired = true;
      connection.close(force: true);
    });
    for (var redirects = 0; ; redirects++) {
      checkUrl(uri);
      final request = await connection.getUrl(uri).timeout(remaining());
      request.followRedirects = false;
      final response = await request.close().timeout(remaining());
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || redirects >= 5) {
          throw const FormatException(
            'Native download redirect limit or location is invalid',
          );
        }
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.listen((_) {}).cancel();
        throw HttpException(
          'Native download HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      if (response.contentLength != -1 &&
          response.contentLength != expectedBytes) {
        await response.listen((_) {}).cancel();
        throw const FormatException('Native download size differs');
      }
      destination.createSync(exclusive: true);
      created = true;
      output = destination.openSync(mode: FileMode.write);
      var count = 0;
      await for (final chunk in response) {
        remaining();
        count += chunk.length;
        if (count > expectedBytes)
          throw const FormatException('Native download exceeds pinned size');
        output.writeFromSync(chunk);
      }
      if (count != expectedBytes)
        throw const FormatException('Native download size differs');
      remaining();
      final completedOutput = output;
      output = null;
      completedOutput.closeSync();
      complete = true;
      return;
    }
  } on Object {
    if (expired) throw TimeoutException('Native download timed out');
    rethrow;
  } finally {
    timer?.cancel();
    connection.close(force: true);
    try {
      output?.closeSync();
    } finally {
      if (created && !complete) destination.deleteSync();
    }
  }
}
