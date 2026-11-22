import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'cie_bridge.dart';

/// Inserimento del PIN della CIE condiviso dalle pagine di firma, con lo
/// sblocco facoltativo tramite biometria o blocco schermo (UC13, D25).
///
/// Se l'utente ha attivato la funzione e c'è un PIN salvato, la pagina propone
/// di sbloccarlo invece di digitarlo; la carta va comunque avvicinata. Se la
/// funzione è attiva ma il PIN non è ancora salvato, lo si salva dopo la prima
/// firma riuscita, così si custodisce solo un PIN che la carta ha accettato.
mixin PinUnlockMixin<T extends StatefulWidget> on State<T> {
  final pinController = TextEditingController();
  VaultStatus vault = const VaultStatus.unavailable();

  /// Si userà il PIN salvato invece di quello digitato.
  bool useSaved = false;

  /// L'ultima sessione è partita con il PIN salvato.
  bool _lastFromVault = false;

  CieBridge get pinBridge;

  @override
  void initState() {
    super.initState();
    refreshVault();
  }

  @override
  void dispose() {
    pinController.dispose();
    super.dispose();
  }

  Future<void> refreshVault() async {
    final s = await pinBridge.vaultStatus();
    if (!mounted) return;
    setState(() {
      vault = s;
      useSaved = s.canUnlock;
    });
  }

  bool get pinReady => useSaved || RegExp(r'^\d{8}$').hasMatch(pinController.text);

  /// PIN da passare a [CieBridge.start]: null vuol dire "usa quello salvato".
  String? takePin() {
    _lastFromVault = useSaved;
    return useSaved ? null : pinController.text;
  }

  /// Dopo una sessione riuscita con PIN digitato, lo salva se l'utente ha attivato
  /// la funzione. Restituisce un messaggio da mostrare, o null.
  Future<String?> rememberPinIfWanted() async {
    final typed = pinController.text;
    pinController.clear();
    if (_lastFromVault || !vault.canSave || typed.length != 8) return null;
    try {
      final s = await pinBridge.savePin(typed);
      if (mounted) setState(() => vault = s);
      return 'PIN salvato: alle prossime firme basterà lo sblocco del telefono e la carta.';
    } on CieError catch (e) {
      if (e.code == 'VAULT_CANCELLED') return 'PIN non salvato: lo potrai salvare alla prossima firma.';
      return 'PIN non salvato: ${e.message}';
    }
  }

  /// Testo per gli errori legati al PIN salvato, o null se l'errore è un altro.
  /// Aggiorna lo stato: dopo un rifiuto si torna al PIN digitato.
  String? vaultErrorText(CieError e) {
    pinController.clear();
    final fromVault = _lastFromVault;
    String? text;
    switch (e.code) {
      case 'VAULT_CANCELLED':
        text = 'Sblocco annullato. Puoi riprovare o inserire il PIN a mano.';
      case 'VAULT_LOCKOUT':
        text = 'Troppi tentativi di sblocco: inserisci il PIN a mano.';
        useSaved = false;
      case 'VAULT_INVALIDATED' || 'VAULT_EMPTY':
        text = 'Le impronte, il volto o il blocco schermo del telefono sono cambiati: per sicurezza il PIN '
            'salvato è stato cancellato. Inseriscilo a mano; dopo la firma potrai salvarlo di nuovo.';
        _forgotten();
      case 'VAULT_ERROR':
        text = 'Sblocco non riuscito (${e.message}). Inserisci il PIN a mano.';
        useSaved = false;
      case 'WRONG_PIN' when fromVault:
        final left = e.remainingAttempts;
        text = 'La carta ha rifiutato il PIN salvato (forse lo hai cambiato o hai avvicinato un\'altra CIE), '
            'quindi è stato cancellato. Tentativi rimasti: ${left ?? '?'}. Inseriscilo a mano.';
        _forgotten();
      case 'PIN_BLOCKED' when fromVault:
        _forgotten();
    }
    if (mounted) setState(() {});
    return text;
  }

  void _forgotten() {
    useSaved = false;
    vault = VaultStatus(
      availability: vault.availability,
      enabled: vault.enabled,
      saved: false,
      deviceCredential: vault.deviceCredential,
    );
  }

  /// Campo del PIN, oppure il riquadro del PIN salvato.
  Widget pinInput(BuildContext context, {required bool busy, VoidCallback? onSubmitted}) {
    final theme = Theme.of(context);
    if (useSaved) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Icon(Icons.fingerprint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'PIN salvato sul telefono: lo sblocchi con '
                    '${vault.deviceCredential ? 'impronta, volto o blocco schermo' : 'impronta o volto'}.',
                  ),
                ),
              ]),
              if (!busy)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => setState(() => useSaved = false),
                    child: const Text('Inserisci il PIN a mano'),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: pinController,
          enabled: !busy,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: 'PIN della CIE (8 cifre)', border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => onSubmitted?.call(),
        ),
        if (vault.canSave)
          Text(
            'Dopo la firma ti chiederemo lo sblocco del telefono per ricordare il PIN.',
            style: theme.textTheme.bodySmall,
          ),
        if (vault.canUnlock && !busy)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() {
                pinController.clear();
                useSaved = true;
              }),
              icon: const Icon(Icons.fingerprint),
              label: const Text('Usa il PIN salvato'),
            ),
          ),
      ],
    );
  }

  /// Nota in fondo alle pagine di firma.
  String get pinFootnote => vault.canUnlock || vault.canSave
      ? 'Firma elettronica avanzata (FEA). Il PIN è custodito cifrato sul telefono, sbloccabile solo da te.'
      : 'Firma elettronica avanzata (FEA). Il PIN resta sul telefono e non viene salvato.';
}

/// Impostazioni dello sblocco del PIN con biometria o blocco schermo.
class PinUnlockSettingsPage extends StatefulWidget {
  const PinUnlockSettingsPage({super.key, required this.bridge});

  final CieBridge bridge;

  @override
  State<PinUnlockSettingsPage> createState() => _PinUnlockSettingsPageState();
}

class _PinUnlockSettingsPageState extends State<PinUnlockSettingsPage> {
  VaultStatus? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await widget.bridge.vaultStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _toggle(bool on) async {
    if (on && !await _confirm()) return;
    try {
      final s = await widget.bridge.setVaultEnabled(on);
      if (!mounted) return;
      setState(() {
        _status = s;
        _error = null;
      });
    } on CieError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _forget() async {
    final s = await widget.bridge.forgetPin();
    if (mounted) setState(() => _status = s);
  }

  Future<bool> _confirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ricordare il PIN della CIE?'),
        content: const SingleChildScrollView(
          child: Text(
            'Il PIN verrà cifrato e custodito nell\'hardware sicuro di questo telefono. Per usarlo servirà ogni '
            'volta lo sblocco del telefono e la tua CIE avvicinata.\n\n'
            'Attenzione: chiunque possa sbloccare questo telefono (per esempio con un\'impronta o un volto '
            'registrati, o conoscendo il suo codice di sblocco) e abbia la tua carta potrà firmare a tuo nome. '
            'Il PIN della CIE è personale: attiva questa funzione solo se il telefono lo usi soltanto tu.\n\n'
            'La firma resta una firma elettronica avanzata (FEA). Il PIN viene salvato alla prossima firma '
            'riuscita e si cancella da solo se cambi impronte o blocco schermo, o se la carta lo rifiuta.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Annulla')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Attiva')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Sblocco del PIN')),
      body: SafeArea(
        child: s == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'Invece di digitare il PIN della CIE a ogni firma, puoi sbloccarlo con impronta, volto'
                    '${s.deviceCredential ? ' o blocco schermo del telefono' : ''}. La carta va comunque '
                    'avvicinata al telefono.',
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sblocca il PIN con biometria'),
                    subtitle: Text(switch (s.availability) {
                      VaultAvailability.ready when s.enabled && s.saved => 'Attivo, PIN salvato',
                      VaultAvailability.ready when s.enabled => 'Attivo: il PIN si salva alla prossima firma',
                      VaultAvailability.ready => 'Disattivato',
                      VaultAvailability.notEnrolled =>
                        'Configura un\'impronta, un volto o un blocco schermo nelle impostazioni del telefono',
                      VaultAvailability.unsupported => 'Non disponibile su questo telefono',
                    }),
                    value: s.enabled,
                    onChanged: s.availability == VaultAvailability.ready || s.enabled ? _toggle : null,
                  ),
                  if (s.saved) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _forget,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Cancella il PIN salvato'),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Text('Come funziona', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Text(
                    '• Il PIN è cifrato con una chiave che non lascia mai l\'hardware sicuro del telefono e si usa '
                    'solo dopo uno sblocco con impronta, volto o blocco schermo.\n'
                    '• Si salva solo un PIN che la carta ha già accettato.\n'
                    '• Se la carta rifiuta il PIN salvato, l\'app lo cancella subito e non lo riprova, così non '
                    'consuma altri tentativi.\n'
                    '• Se aggiungi un\'impronta o un volto, o togli il blocco schermo, il PIN salvato smette di '
                    'funzionare e va inserito di nuovo.\n'
                    '• Il PIN non è incluso nei backup del telefono e non viene mai inviato al PC.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }
}
