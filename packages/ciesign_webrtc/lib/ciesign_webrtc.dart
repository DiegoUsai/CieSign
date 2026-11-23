/// Collegamento via internet di CIE Sign con **WebRTC**: un data channel
/// diretto tra PC e smartphone, aperto dopo aver scambiato offerta e risposta
/// nel servizio di signaling ([Rendezvous] di `ciesign_link`).
///
/// Sopra il data channel viaggiano gli stessi frame della rete locale, con la
/// stessa stretta di mano e la stessa cifratura end-to-end: WebRTC aggiunge
/// la propria cifratura (**DTLS**), ma il protocollo non ne dipende.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:ciesign_link/ciesign_link.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// [PeerLinkFactory] da passare a [Rendezvous].
Future<PeerLink> createWebRtcPeer(List<IceServer> iceServers) => WebRtcPeerLink.create(iceServers);

class WebRtcPeerLink implements PeerLink {
  WebRtcPeerLink._(this._pc, this._dc) {
    _dc.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen && !_open.isCompleted) {
        _open.complete(_frames = WebRtcFrameChannel._(this));
      } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
        _frames?._closed();
        if (!_open.isCompleted) _open.completeError(const LinkException('Collegamento WebRTC chiuso'));
      }
    };
    _dc.onMessage = (m) => _frames?._onMessage(m);
    _pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _frames?._closed();
        if (!_open.isCompleted) {
          _open.completeError(
            const LinkException('Collegamento diretto non riuscito: le due reti non lo permettono senza un server TURN'),
          );
        }
      }
    };
  }

  static Future<WebRtcPeerLink> create(List<IceServer> iceServers) async {
    final pc = await createPeerConnection({
      'iceServers': [for (final s in iceServers) s.toJson()],
      'sdpSemantics': 'unified-plan',
    });
    // Canale negoziato in anticipo con lo stesso id dai due lati: non serve
    // aspettare l'evento onDataChannel.
    final dc = await pc.createDataChannel(
      'ciesign',
      RTCDataChannelInit()
        ..negotiated = true
        ..id = 0
        ..ordered = true,
    );
    return WebRtcPeerLink._(pc, dc);
  }

  final RTCPeerConnection _pc;
  final RTCDataChannel _dc;
  final _open = Completer<FrameChannel>();
  WebRtcFrameChannel? _frames;

  @override
  Future<FrameChannel> get channel => _open.future;

  /// Attende la fine della raccolta dei candidati ICE (al massimo qualche
  /// secondo), così l'SDP contiene già tutto e non serve il "trickle".
  Future<String> _completeLocal(RTCSessionDescription d) async {
    final done = Completer<void>();
    _pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    await _pc.setLocalDescription(d);
    if (_pc.iceGatheringState != RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await done.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    final local = await _pc.getLocalDescription();
    return local!.sdp!;
  }

  @override
  Future<String> createOffer() async => _completeLocal(await _pc.createOffer());

  @override
  Future<String> acceptOffer(String offerSdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    return _completeLocal(await _pc.createAnswer());
  }

  @override
  Future<void> acceptAnswer(String answerSdp) => _pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));

  @override
  Future<void> close() async {
    _frames?._closed();
    try {
      await _dc.close();
    } on Object {
      // già chiuso
    }
    await _pc.close();
  }
}

/// Il data channel visto come [FrameChannel], con i frame spezzati in pezzi
/// da 16 KB ([Fragmenter]).
class WebRtcFrameChannel implements FrameChannel {
  WebRtcFrameChannel._(this._peer);

  final WebRtcPeerLink _peer;
  final _in = StreamController<Uint8List>();
  final _frag = Fragmenter();

  @override
  Stream<Uint8List> get frames => _in.stream;

  void _onMessage(RTCDataChannelMessage m) {
    if (!m.isBinary || _in.isClosed) return;
    try {
      final f = _frag.join(m.binary);
      if (f != null) _in.add(f);
    } on LinkException catch (e) {
      _in.addError(e);
      close();
    }
  }

  void _closed() {
    if (!_in.isClosed) _in.close();
  }

  @override
  void send(Uint8List frame) {
    for (final p in _frag.split(frame)) {
      _peer._dc.send(RTCDataChannelMessage.fromBinary(p));
    }
  }

  @override
  Future<void> close() => _peer.close();
}
