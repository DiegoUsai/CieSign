import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ciesign_link/ciesign_link.dart';

/// Servizio di signaling finto, compatibile con il sottoinsieme dell'API REST
/// del Firebase Realtime Database usato da [SignalingClient] (lo stesso che
/// implementa il Worker di Cloudflare).
class FakeSignalingServer {
  FakeSignalingServer._(this._server, this.requireAuth);

  static Future<FakeSignalingServer> start({bool requireAuth = false}) async {
    final s = FakeSignalingServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), requireAuth);
    s._server.listen(s._handle);
    return s;
  }

  final HttpServer _server;
  final bool requireAuth;
  Map<String, Object?> data = {};
  final _watchers = <(List<String>, HttpResponse)>[];
  final log = <String>[];
  int signUps = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  Object? _at(List<String> p) {
    Object? n = data;
    for (final k in p) {
      if (n is! Map) return null;
      n = n[k];
    }
    return n;
  }

  Object? _resolve(Object? v) {
    if (v is Map) {
      if (v.length == 1 && v['.sv'] == 'timestamp') return DateTime.now().millisecondsSinceEpoch;
      return {for (final e in v.entries) e.key as String: _resolve(e.value)};
    }
    return v;
  }

  void _set(List<String> p, Object? v) {
    if (p.isEmpty) {
      data = (v as Map<String, Object?>?) ?? {};
      return;
    }
    var n = data;
    for (final k in p.sublist(0, p.length - 1)) {
      n = (n[k] ??= <String, Object?>{}) as Map<String, Object?>;
    }
    if (v == null) {
      n.remove(p.last);
    } else {
      n[p.last] = v;
    }
  }

  Future<void> _handle(HttpRequest rq) async {
    final path = rq.uri.path;
    log.add('${rq.method} $path');
    if (path.endsWith('accounts:signUp')) {
      signUps++;
      await utf8.decoder.bind(rq).join();
      rq.response.headers.contentType = ContentType.json;
      rq.response.write(jsonEncode({'idToken': 'tok$signUps', 'refreshToken': 'r', 'expiresIn': '3600'}));
      await rq.response.close();
      return;
    }
    if (requireAuth && rq.uri.queryParameters['auth'] == null) {
      rq.response.statusCode = 401;
      rq.response.write('{"error":"Permission denied"}');
      await rq.response.close();
      return;
    }
    if (!path.endsWith('.json')) {
      rq.response.statusCode = 404;
      await rq.response.close();
      return;
    }
    final p = path.substring(1, path.length - 5).split('/').where((s) => s.isNotEmpty).toList();
    switch (rq.method) {
      case 'GET' when rq.headers.value(HttpHeaders.acceptHeader) == 'text/event-stream':
        final rs = rq.response;
        rs.headers.contentType = ContentType('text', 'event-stream');
        rs.bufferOutput = false;
        _watchers.add((p, rs));
        _send(rs, _at(p));
      case 'GET':
        rq.response.headers.contentType = ContentType.json;
        rq.response.write(jsonEncode(_at(p)));
        await rq.response.close();
      case 'PUT':
        final v = _resolve(jsonDecode(await utf8.decoder.bind(rq).join()));
        _set(p, v);
        rq.response.write(jsonEncode(v));
        await rq.response.close();
        _notify();
      case 'DELETE':
        await rq.drain<void>();
        _set(p, null);
        rq.response.write('null');
        await rq.response.close();
        _notify();
      default:
        rq.response.statusCode = 405;
        await rq.response.close();
    }
  }

  void _send(HttpResponse rs, Object? v) {
    try {
      rs.write('event: put\ndata: ${jsonEncode({'path': '/', 'data': v})}\n\n');
    } on Object {
      // ascoltatore già chiuso
    }
  }

  void _notify() {
    for (final (p, rs) in _watchers) {
      _send(rs, _at(p));
    }
  }

  Future<void> close() async {
    for (final (_, rs) in _watchers) {
      try {
        await rs.close();
      } on Object {
        // già chiusa
      }
    }
    await _server.close(force: true);
  }
}

/// Coppia di [FrameChannel] collegati in memoria.
class MemoryFrameChannel implements FrameChannel {
  MemoryFrameChannel._();

  static (MemoryFrameChannel, MemoryFrameChannel) pair() {
    final a = MemoryFrameChannel._(), b = MemoryFrameChannel._();
    a._peer = b;
    b._peer = a;
    return (a, b);
  }

  late MemoryFrameChannel _peer;
  final _in = StreamController<Uint8List>();

  @override
  Stream<Uint8List> get frames => _in.stream;

  @override
  void send(Uint8List frame) {
    if (!_peer._in.isClosed) _peer._in.add(frame);
  }

  @override
  Future<void> close() async {
    if (!_in.isClosed) await _in.close();
    if (!_peer._in.isClosed) await _peer._in.close();
  }
}

/// [PeerLink] finto: l'SDP è solo un identificativo e il "collegamento
/// diretto" è una coppia di canali in memoria.
class FakePeerLink implements PeerLink {
  FakePeerLink(this.iceServers, {this.fail = false});

  static final _offers = <String, FakePeerLink>{};
  static var _n = 0;

  final List<IceServer> iceServers;
  final bool fail;
  final _channel = Completer<FrameChannel>();
  MemoryFrameChannel? _pending;
  bool closed = false;

  @override
  Future<String> createOffer() async {
    final id = 'offer-${_n++}';
    _offers[id] = this;
    return id;
  }

  @override
  Future<String> acceptOffer(String offerSdp) async {
    final offerer = _offers.remove(offerSdp);
    if (offerer == null) throw const LinkException('offerta sconosciuta');
    final (mine, theirs) = MemoryFrameChannel.pair();
    if (!fail) _channel.complete(mine);
    offerer._pending = theirs;
    return 'answer-for-$offerSdp';
  }

  @override
  Future<void> acceptAnswer(String answerSdp) async {
    final p = _pending;
    if (p != null && !fail) _channel.complete(p);
  }

  @override
  Future<FrameChannel> get channel => _channel.future;

  @override
  Future<void> close() async => closed = true;
}
