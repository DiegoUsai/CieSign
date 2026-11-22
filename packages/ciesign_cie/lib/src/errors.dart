/// Radice delle eccezioni del dialogo con la CIE.
class CieException implements Exception {
  CieException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// La carta avvicinata non è una CIE o non espone l'applicazione IAS ECC.
class NotACieException extends CieException {
  NotACieException(String detail) : super('La carta non risponde come una CIE 3.0 ($detail)');
}

/// PIN errato: [remainingAttempts] indica i tentativi rimasti prima del blocco.
class WrongPinException extends CieException {
  WrongPinException(this.remainingAttempts) : super('PIN errato, tentativi rimasti: $remainingAttempts');
  final int remainingAttempts;
}

/// PIN bloccato: serve il PUK per sbloccarlo.
class PinBlockedException extends CieException {
  PinBlockedException() : super('PIN bloccato, serve il PUK');
}

/// Il PIN inserito non ha il formato atteso (8 cifre).
class InvalidPinFormatException extends CieException {
  InvalidPinFormatException() : super('Il PIN della CIE è composto da 8 cifre');
}

/// Errore nella cifratura o nella verifica del secure messaging.
class SecureMessagingException extends CieException {
  SecureMessagingException(super.message);
}

/// Risposta inattesa della carta a un comando.
class CieProtocolException extends CieException {
  CieProtocolException(super.message);
}

/// La carta ha risposto con uno status word di errore.
class CardStatusException extends CieProtocolException {
  CardStatusException(this.step, this.sw)
      : super('Errore della carta durante "$step": SW=${sw.toRadixString(16).toUpperCase().padLeft(4, '0')}');
  final String step;
  final int sw;
}
