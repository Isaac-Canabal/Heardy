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
import '../widgets/max_width_center.dart';
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

class _MainShellScreenState extends State<MainShellScreen>
    with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // `MainShellScreen` es el único sitio del árbol con un BuildContext real
    // bajo MaterialApp que se construye una sola vez por proceso (main.dart
    // corre fuera del árbol, sin BuildContext ni navigatorKey) — ver
    // CLAUDE.md, Etapa 16 / B2.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeShowAccountPrompt(),
    );
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
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
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

  /// A partir de acá la ventana da para el diseño de dos columnas (barra
  /// lateral + contenido). Por debajo se usa el diseño de teléfono tal cual,
  /// que es también lo que ve Android siempre — ver W3 del plan de
  /// escritorio.
  static const double desktopBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    // Suscribirse a SettingsProvider para redibujar instantáneamente cuando cambie el tema/idioma
    Provider.of<SettingsProvider>(context);
    final inboxCount = context.watch<MusicProvider>().inboxCount;
    // pendingCount ya cuenta el trabajo que se está descargando ahora mismo:
    // sigue en download_queue (la fila SQLite) hasta que termina, y el
    // provider sólo refresca su lista en memoria al principio de cada
    // iteración del bucle — así que sumarle +1 por "current" lo contaría dos
    // veces.
    final downloadCount = context.watch<DownloadProvider>().pendingCount;
    final isDesktopLayout =
        MediaQuery.of(context).size.width >= desktopBreakpoint;

    return isDesktopLayout
        ? _buildDesktopLayout(context, inboxCount, downloadCount)
        : _buildMobileLayout(context, inboxCount, downloadCount);
  }

  /// Dos columnas: barra lateral de navegación + playlists a la izquierda,
  /// contenido a todo el ancho restante, y el mini player abajo cruzando las
  /// dos columnas (igual que cualquier reproductor de escritorio).
  Widget _buildDesktopLayout(
    BuildContext context,
    int inboxCount,
    int downloadCount,
  ) {
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Column(
          children: [
            Expanded(
              child: Row(
                // `stretch` es lo que le da altura real a las dos columnas.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _DesktopSidebar(
                    selectedIndex: _index,
                    inboxCount: inboxCount,
                    downloadCount: downloadCount,
                    onSelect: (i) => setState(() => _index = i),
                  ),
                  const VerticalDivider(width: 1, color: Colors.white12),
                  Expanded(child: _buildTabs()),
                ],
              ),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }

  /// El diseño de siempre, el de teléfono: pestañas abajo y contenido
  /// centrado con ancho máximo. Es lo que ve Android, sin cambios.
  Widget _buildMobileLayout(
    BuildContext context,
    int inboxCount,
    int downloadCount,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        // Centrado con ancho máximo — la interfaz está pensada para un
        // teléfono (~360-430dp). En una ventana de escritorio angosta, esto
        // la centra en vez de estirarla; en una pantalla de teléfono real el
        // ancho disponible ya es menor que el máximo, así que no cambia nada.
        child: MaxWidthCenter(
          child: Stack(
            children: [
              _buildTabs(),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: MiniPlayer(),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: MaxWidthCenter(
        stretchHeight: false,
        child: NavigationBar(
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
      ),
    );
  }

  /// Las cinco pantallas, compartidas por los dos diseños — un solo
  /// `IndexedStack` para que cambiar de sección (o de diseño al
  /// redimensionar la ventana) no pierda el estado de ninguna.
  Widget _buildTabs() {
    return IndexedStack(
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
    );
  }
}

/// Barra lateral del diseño de escritorio: las mismas cinco secciones que la
/// barra inferior del teléfono, en vertical, más la lista de playlists
/// siempre a mano (lo que en el teléfono exige entrar a Inicio primero).
class _DesktopSidebar extends StatelessWidget {
  final int selectedIndex;
  final int inboxCount;
  final int downloadCount;
  final ValueChanged<int> onSelect;

  const _DesktopSidebar({
    required this.selectedIndex,
    required this.inboxCount,
    required this.downloadCount,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final playlists = context.watch<MusicProvider>().playlists;

    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Row(
              children: [
                Icon(
                  Icons.graphic_eq_rounded,
                  color: AppTheme.primaryLight,
                  size: 22,
                ),
                const SizedBox(width: 10),
                const Text(
                  'Heardy',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          _SidebarItem(
            icon: Icons.library_music_outlined,
            selectedIcon: Icons.library_music_rounded,
            label: l10n.homeTitle,
            selected: selectedIndex == 0,
            onTap: () => onSelect(0),
          ),
          _SidebarItem(
            icon: Icons.inbox_outlined,
            selectedIcon: Icons.inbox_rounded,
            label: l10n.navInbox,
            badgeCount: inboxCount,
            selected: selectedIndex == 1,
            onTap: () => onSelect(1),
          ),
          _SidebarItem(
            icon: Icons.cloud_download_outlined,
            selectedIcon: Icons.cloud_download_rounded,
            label: l10n.navAdd,
            badgeCount: downloadCount,
            selected: selectedIndex == 2,
            onTap: () => onSelect(2),
          ),
          _SidebarItem(
            icon: Icons.search_outlined,
            selectedIcon: Icons.search_rounded,
            label: l10n.searchTitle,
            selected: selectedIndex == 3,
            onTap: () => onSelect(3),
          ),
          _SidebarItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings_rounded,
            label: l10n.settingsTitle,
            selected: selectedIndex == 4,
            onTap: () => onSelect(4),
          ),
          const Divider(
            height: 28,
            indent: 20,
            endIndent: 20,
            color: Colors.white12,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              l10n.homeTitle.toUpperCase(),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      l10n.homeEmptyTitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 12,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          Icons.queue_music_rounded,
                          size: 18,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                        title: Text(
                          playlist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 13,
                          ),
                        ),
                        onTap: () => Navigator.of(
                          context,
                        ).pushNamed('/playlist', arguments: playlist.id),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final int badgeCount;
  final bool selected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? AppTheme.primaryLight
        : Colors.white.withValues(alpha: 0.75);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: selected
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Badge(
                  isLabelVisible: badgeCount > 0,
                  label: Text('$badgeCount'),
                  child: Icon(
                    selected ? selectedIcon : icon,
                    size: 20,
                    color: color,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
