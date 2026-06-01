import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'add_from_youtube_screen.dart';
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

    return Scaffold(
      body: Container(
        decoration: AppTheme.gradientScaffold(),
        child: Stack(
          children: [
            IndexedStack(
              index: _index,
              children: const [
                HomeScreen(),
                AddFromYouTubeScreen(embedInShell: true),
                SettingsScreen(),
              ],
            ),
            const Positioned(
              left: 0,
              right: 0,
              bottom: 72,
              child: MiniPlayer(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 68,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.library_music_outlined),
            selectedIcon: Icon(Icons.library_music_rounded),
            label: 'Mis playlists',
          ),
          NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download_rounded),
            label: 'Descargas',
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
