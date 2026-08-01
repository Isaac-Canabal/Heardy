import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/download_provider.dart';
import '../providers/music_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
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

class _MainShellScreenState extends State<MainShellScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Suscribirse a SettingsProvider para redibujar instantáneamente cuando cambie el tema
    Provider.of<SettingsProvider>(context);
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
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music_rounded),
            label: 'Mis playlists',
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
            label: 'Bandeja',
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
            label: 'Añadir',
          ),
          NavigationDestination(
            icon: Icon(Icons.search_outlined),
            selectedIcon: Icon(Icons.search_rounded),
            label: 'Buscar',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded),
            label: 'Ajustes',
          ),
        ],
      ),
    );
  }
}
