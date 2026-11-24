import 'package:material_ui/material_ui.dart';

import 'cie_bridge.dart';
import 'link_service.dart';
import 'pin_unlock.dart';

/// Icona di stato del PC nella barra in alto (solo con un PC abbinato).
class PcStatusIcon extends StatelessWidget {
  const PcStatusIcon({super.key, required this.link, required this.onTap});

  final PhoneLink link;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        if (link.pc == null) return const SizedBox.shrink();
        final name = link.pc!.device.name;
        final (IconData icon, Color? color, String tip) = switch (link.state) {
          LinkState.connected => (Icons.computer, Colors.greenAccent, 'Collegato a $name'),
          LinkState.connecting => (Icons.sync, null, 'Collegamento a $name…'),
          _ => (Icons.desktop_access_disabled, Theme.of(context).colorScheme.error, '$name non raggiungibile'),
        };
        return IconButton(tooltip: tip, onPressed: onTap, icon: Icon(icon, color: color));
      },
    );
  }
}

/// Impostazioni: collegamento al PC, sblocco del PIN, prova della carta, informazioni.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.bridge,
    required this.link,
    required this.onScan,
    required this.openPrototype,
    required this.buildId,
  });

  final CieBridge bridge;
  final PhoneLink? link;
  final VoidCallback onScan;
  final VoidCallback openPrototype;
  final String buildId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = this.link;
    return Scaffold(
      appBar: AppBar(title: const Text('Impostazioni')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Collegamento al PC', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            if (link == null)
              const Card(child: ListTile(title: Text('Collegamento non disponibile')))
            else
              ListenableBuilder(listenable: link, builder: (context, _) => PcLinkCard(link: link, onScan: onScan)),
            const SizedBox(height: 24),
            Text('Firma', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.fingerprint),
                title: const Text('Sblocco del PIN'),
                subtitle: const Text('Facoltativo: firma con impronta, volto o blocco schermo invece di digitare il PIN'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => PinUnlockSettingsPage(bridge: bridge)),
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.badge),
                title: const Text('Prova la carta'),
                subtitle: Text(
                  link?.certificate != null
                      ? 'Certificato della CIE registrato sul telefono'
                      : 'Legge il certificato e lo registra per le firme dal PC',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: openPrototype,
              ),
            ),
            const SizedBox(height: 24),
            Text('Informazioni', style: theme.textTheme.titleSmall),
            Card(child: ListTile(leading: const Icon(Icons.info_outline), title: const Text('Firmami'), subtitle: Text('Build $buildId'))),
          ],
        ),
      ),
    );
  }
}

/// Stato del collegamento con il PC e azioni (abbina, ricollega, dimentica).
class PcLinkCard extends StatelessWidget {
  const PcLinkCard({super.key, required this.link, required this.onScan});

  final PhoneLink link;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pcName = link.pc?.device.name;
    final (IconData icon, Color? color, String title, String text) = switch (link.state) {
      LinkState.notPaired => (
        Icons.qr_code_scanner,
        null,
        'Nessun PC abbinato',
        'Serve solo per firmare dal PC: sul telefono puoi firmare anche senza. Sul PC apri Firmami, '
            'scegli "Abbina smartphone" e inquadra il QR code con il pulsante qui sotto o con la fotocamera'
            '.${link.remoteEnabled ? '' : ' Telefono e PC devono essere sulla stessa Wi-Fi.'}',
      ),
      LinkState.connected => (
        Icons.link,
        Colors.green,
        'Collegato a $pcName',
        '${link.viaInternet ? 'Via internet. ' : ''}In attesa di richieste dal PC. Tieni aperta l\'app durante la firma.',
      ),
      LinkState.connecting => (Icons.sync, null, 'Collegamento a $pcName…', ''),
      LinkState.disconnected => (
        Icons.link_off,
        theme.colorScheme.error,
        '$pcName non raggiungibile',
        link.remoteEnabled
            ? 'Controlla che Firmami sia aperto sul PC e che PC e telefono siano collegati a internet.'
            : 'Controlla che Firmami sia aperto sul PC e che i due dispositivi siano sulla stessa Wi-Fi.',
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ]),
            if (text.isNotEmpty) ...[const SizedBox(height: 8), Text(text)],
            if (link.state == LinkState.disconnected && link.lastError != null) ...[
              const SizedBox(height: 8),
              Text(link.lastError!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            if (link.state == LinkState.notPaired)
              FilledButton.icon(onPressed: onScan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Abbina PC')),
            if (link.state == LinkState.disconnected && link.suggestInternet && !link.internetEnabled) ...[
              const Text(
                'Se il telefono non è sulla stessa rete del PC, per esempio in 4G o su un\'altra Wi-Fi, '
                'puoi collegarti via internet. Sul PC va attivata la stessa opzione.',
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  link.setInternetEnabled(true);
                  link.connect();
                },
                icon: const Icon(Icons.public),
                label: const Text('Non sono sulla stessa rete'),
              ),
              const SizedBox(height: 8),
            ],
            if (link.state == LinkState.disconnected)
              FilledButton.icon(onPressed: link.connect, icon: const Icon(Icons.refresh), label: const Text('Ricollega')),
            if (link.remoteAvailable && link.state != LinkState.notPaired)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Non sono sulla stessa rete'),
                subtitle: const Text('Collegamento via internet quando il PC non è sulla rete locale'),
                value: link.internetEnabled,
                onChanged: (v) {
                  link.setInternetEnabled(v);
                  if (v && link.state == LinkState.disconnected) link.connect();
                },
              ),
            if (link.pc != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: onScan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Abbina un altro PC')),
              TextButton(onPressed: link.unpair, child: const Text('Dimentica il PC')),
            ],
          ],
        ),
      ),
    );
  }
}
