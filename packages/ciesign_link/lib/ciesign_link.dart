/// Protocollo di CIE Sign tra PC e smartphone, versione 1 (bozza).
///
/// - Abbinamento una tantum: il PC mostra un QR code ([PairingOffer]), lo
///   smartphone lo inquadra, entrambi mostrano lo stesso codice di sei cifre e
///   l'utente lo conferma ([PairConfirm]).
/// - Riconnessione automatica con chiavi statiche ed effimere ([Handshake]).
/// - Canale cifrato ([SecureChannel]) su un trasporto a frame: TCP sulla Wi-Fi
///   di casa ([TcpFrameChannel]) oppure, in seguito, Bluetooth Low Energy.
/// - Collegamento via internet ([Rendezvous]): offerta e risposta **WebRTC**
///   cifrate in una stanza di un servizio di signaling ([SignalingClient]),
///   Firebase Realtime Database oggi, Cloudflare Worker domani.
/// - Messaggi di firma ([SignRequest], [SignResponse], ...).
library;

export 'src/channel.dart';
export 'src/keys.dart' show DeviceIdentity, PairedDevice;
export 'src/messages.dart';
export 'src/pairing_offer.dart';
export 'src/remote/rendezvous.dart';
export 'src/remote/signaling.dart';
export 'src/tcp.dart';
