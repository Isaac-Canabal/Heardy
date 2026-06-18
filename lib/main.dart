import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'services/database_helper.dart';
import 'services/audio_player_handler.dart';
import 'providers/music_provider.dart';
import 'providers/download_provider.dart';
import 'providers/settings_provider.dart';
import 'screens/main_shell_screen.dart';
import 'screens/playlist_detail_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await DatabaseHelper.instance.database;

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  final AudioPlayerHandler audioHandler = await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.heardy.app.audio',
      androidNotificationChannelName: 'Heardy Playback',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
      artDownscaleWidth: 300,
      artDownscaleHeight: 300,
    ),
  );

  if (Platform.isAndroid) {
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<AudioPlayerHandler>.value(value: audioHandler),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => MusicProvider()),
        ChangeNotifierProxyProvider2<MusicProvider, AudioPlayerHandler, DownloadProvider>(
          create: (_) => DownloadProvider()..initQueue(),
          update: (_, musicProvider, audioHandler, downloadProvider) {
            downloadProvider!.musicProvider = musicProvider;
            downloadProvider.audioHandler = audioHandler;
            
            // Restaurar estado de reproducción después de que todo esté inicializado
            // Usar Future.microtask para asegurar que se ejecute después del build inicial
            Future.microtask(() async {
              await musicProvider.restorePlaybackState(audioHandler);
            });
            
            return downloadProvider;
          },
        ),
      ],
      child: const HeardyApp(),
    ),
  );
}

class HeardyApp extends StatelessWidget {
  const HeardyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        AppTheme.applyPreset(settings.preset);
        return MaterialApp(
          title: 'Heardy',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          initialRoute: '/',
          onGenerateRoute: RouteGenerator.generateRoute,
        );
      },
    );
  }
}

class RouteGenerator {
  static Route<dynamic> generateRoute(RouteSettings settings) {
    final args = settings.arguments;

    switch (settings.name) {
      case '/':
        return MaterialPageRoute(builder: (_) => const MainShellScreen());
      case '/playlist':
        if (args is String) {
          return MaterialPageRoute(
            builder: (_) => PlaylistDetailScreen(playlistId: args),
          );
        }
        return _errorRoute('ID de lista inválido');
      default:
        return _errorRoute('Ruta no encontrada');
    }
  }

  static Route<dynamic> _errorRoute(String message) {
    return MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Center(
          child: Text(
            message,
            style: const TextStyle(fontSize: 16, color: Colors.redAccent),
          ),
        ),
      ),
    );
  }
}
