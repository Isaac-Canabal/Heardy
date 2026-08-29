import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/sync_provider.dart';
import '../services/account_prompt.dart';
import '../services/database_helper.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import '../l10n/app_localizations.dart';
import 'auth/login_screen.dart';
import 'home_screen.dart';
import 'import_screen.dart';
import 'inbox_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class MainShellScreen extends StatefulWidget {
  const MainShellScreen({super.key});

  @override
  State<MainShellScreen> createState() => _MainShellScreenState();
}

class _MainShellScreenState extends State<MainShellScreen> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // `MainShellScreen` es el único sitio del árbol con un BuildContext real
    // bajo MaterialApp que se construye una sola vez por proceso (main.dart
    // corre fuera del árbol, sin BuildContext ni navigatorKey) — ver
    // CLAUDE.md, Etapa 16 / B2.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowAccountPrompt());
  }

  Future<void> _maybeShowAccountPrompt() async {
    final settings = context.read<SettingsProvider>();
    final auth = context.read<HeardyAuthProvider>();
    // Sin esto, `isLoaded` leería siempre el valor por defecto en un
    // callback de una sola pasada — el bug más probable de toda esta función.
    await settings.ensureLoaded();
    if (!mounted) return;

    final songCount = await DatabaseHelper.instance.getLibrarySongCount();
    if (!mounted) return;

    final show = shouldShowAccountPrompt(
      loaded: settings.isLoaded,
      seen: settings.accountPromptSeen,
      // `isSignedIn`, no `isReady`: quien se registró pero no verificó el
      // correo todavía ya aceptó la invitación, y `LoginScreen` se
      // auto-cierra al pasar a `isReady` — un popup compitiendo con esa
      // transición parpadearía.
      signedIn: auth.isSignedIn,
      songCount: songCount,
    );
    if (!show) return;

    final l10n = AppLocalizations.of(context)!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.accountPromptTitle),
        content: Text(l10n.accountPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.accountPromptNotNow),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              );
            },
            child: Text(l10n.accountPromptCreateAccount),
          ),
        ],
      ),
    );
    // En TODAS las salidas (la X, tocar afuera, el botón atrás, y los dos
    // botones de arriba) — nunca sólo en "Ahora no".
    if (mounted) await context.read<SettingsProvider>().markAccountPromptSeen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Red de seguridad además del foreground service: si igual se congeló o
    // mató el proceso mientras la app estaba en segundo plano (el service no
    // es garantía absoluta en todos los fabricantes/versiones de Android),
    // volver a primer plano es una señal razonable de "puede que haya que
    // retomar la cola" — igual que ya se hace en el arranque en frío
    // (main.dart), sin necesidad de un polling propio.
    final downloadProvider = context.read<DownloadProvider>();
    downloadProvider.processQueue();
    downloadProvider.retryPendingImports();
    // Estrangulado por dentro (15 min) — ver SyncProvider.onAppResumed.
    context.read<SyncProvider>().onAppResumed();
  }

  @override
  Widget build(BuildContext context) {
    // Suscribirse a SettingsProvider para redibujar instantáneamente cuando cambie el tema/idioma
    Provider.of<SettingsProvider>(context);
    final l10n = AppLocalizations.of(context)!;
    final inboxCount = context.watch<MusicProvider>().inboxCount;
    // pendingCount ya cuenta el trabajo que se está descargando ahora mismo:
    // sigue en download_queue (la fila SQLite) hasta que termina, y el
    // provider sólo refresca su lista en memoria al principio de cada
    // iteración del bucle — así que sumarle +1 por "current" lo contaría dos
    // veces.
    final downloadCount = context.watch<DownloadProvider>().pendingCount;

    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            IndexedStack(
              index: _index,
              // ImportScreen ya no es const (Fase 8: toma un SpotifyService
              // inyectable para tests), así que la lista entera deja de serlo.
              children: [
                const HomeScreen(),
                const InboxScreen(),
                ImportScreen(),
                const SearchScreen(),
                const SettingsScreen(),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: MiniPlayer(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 68,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.library_music_outlined),
            selectedIcon: const Icon(Icons.library_music_rounded),
            label: l10n.homeTitle,
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: inboxCount > 0,
              label: Text('$inboxCount'),
              child: const Icon(Icons.inbox_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: inboxCount > 0,
              label: Text('$inboxCount'),
              child: const Icon(Icons.inbox_rounded),
            ),
            label: l10n.navInbox,
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: downloadCount > 0,
              label: Text('$downloadCount'),
              child: const Icon(Icons.cloud_download_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: downloadCount > 0,
              label: Text('$downloadCount'),
              child: const Icon(Icons.cloud_download_rounded),
            ),
            label: l10n.navAdd,
          ),
          NavigationDestination(
            icon: const Icon(Icons.search_outlined),
            selectedIcon: const Icon(Icons.search_rounded),
            label: l10n.searchTitle,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings_rounded),
            label: l10n.settingsTitle,
          ),
        ],
      ),
    );
  }
}
