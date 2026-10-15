// Test-only TLS credentials are generated locally, never stored in source.
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<({SecurityContext context, File certificate})> createLoopbackTls(
  Directory root,
) async {
  final directory = root.createTempSync('tls-');
  try {
    File(p.join(directory.path, 'openssl.cnf')).writeAsStringSync('''
[req]
prompt = no
distinguished_name = subject
x509_extensions = server
[subject]
CN = localhost
[server]
subjectAltName = DNS:localhost,IP:127.0.0.1
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
''');
    final child = await Process.start(
      Platform.environment['ARCHWAY_TEST_OPENSSL'] ?? 'openssl',
      [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-sha256',
        '-days',
        '1',
        '-config',
        'openssl.cnf',
        '-keyout',
        'key.pem',
        '-out',
        'cert.pem',
      ],
      workingDirectory: directory.path,
    );
    // OpenSSL's progress is not fixture output, and key bytes are never logged.
    final streams = Future.wait([
      child.stdout.drain<void>(),
      child.stderr.drain<void>(),
    ]);
    try {
      final exit = await child.exitCode.timeout(const Duration(seconds: 30));
      await streams;
      if (exit != 0) {
        throw StateError('Loopback TLS certificate generation exited $exit');
      }
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode.timeout(const Duration(seconds: 5));
      await streams;
      rethrow;
    }
    final certificate = File(p.join(directory.path, 'cert.pem'));
    final key = File(p.join(directory.path, 'key.pem'));
    final context = SecurityContext()
      ..useCertificateChain(certificate.path)
      ..usePrivateKey(key.path);
    key.deleteSync();
    return (context: context, certificate: certificate);
  } catch (_) {
    directory.deleteSync(recursive: true);
    rethrow;
  }
}
