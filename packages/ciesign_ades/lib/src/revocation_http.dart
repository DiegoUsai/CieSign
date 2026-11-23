import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'revocation.dart';

/// Accesso a OCSP e CRL via HTTP con dart:io, valido su Windows, macOS,
/// Linux, Android e iOS. Limita tempo e dimensione delle risposte.
class HttpRevocationFetcher implements RevocationFetcher {
  HttpRevocationFetcher({this.timeout = const Duration(seconds: 15), this.maxBytes = 64 * 1024 * 1024});

  final Duration timeout;
  final int maxBytes;
  final _client = HttpClient()..userAgent = 'CIE Sign';

  @override
  Future<Uint8List> get(Uri url) => _send(() => _client.getUrl(url));

  @override
  Future<Uint8List> post(Uri url, Uint8List body, String contentType) => _send(() async {
    final req = await _client.postUrl(url);
    req.headers.contentType = ContentType.parse(contentType);
    req.contentLength = body.length;
    req.add(body);
    return req;
  });

  Future<Uint8List> _send(Future<HttpClientRequest> Function() open) async {
    final req = await open().timeout(timeout);
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('risposta HTTP ${res.statusCode}');
    }
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(timeout)) {
      b.add(chunk);
      if (b.length > maxBytes) throw const HttpException('risposta troppo grande');
    }
    return b.takeBytes();
  }

  void close() => _client.close(force: true);
}
