import 'package:flutter/widgets.dart';

/// Colori del marchio. Il rosso richiama l'inchiostro e tiene l'app lontana
/// dall'aspetto istituzionale (niente blu né tricolore).
abstract final class FirmamiColors {
  /// Rosso principale: icona, colore di base del tema.
  static const red = Color(0xFFD81E3F);

  /// Rosso scuro, fondo della sfumatura dello splash.
  static const redDeep = Color(0xFFA3122D);

  /// Corallo, punto luminoso della sfumatura dello splash.
  static const coral = Color(0xFFFF6B5B);

  /// Nome pubblico dell'app.
  static const appName = 'Firmami';

  /// Frase sotto il nome.
  static const tagline = 'La tua firma, dal telefono';
}
