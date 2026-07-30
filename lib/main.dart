import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

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

  final musicProvider = MusicProvider();

  runApp(
    MultiProvider(
      providers: [
        Provider<AudioPlayerHandler>.value(value: audioHandler),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider.value(value: musicProvider),
        ChangeNotifierProxyProvider2<MusicProvider, AudioPlayerHandler, DownloadProvider>(
          create: (_) => DownloadProvider()..initQueue(),
          update: (_, musicProvider, audioHandler, downloadProvider) {
            downloadProvider!.musicProvider = musicProvider;
            downloadProvider.audioHandler = audioHandler;
            return downloadProvider;
          },
        ),
      ],
      child: const HeardyApp(),
    ),
  );

  // Restaurar estado de reproducción una vez que el primer frame ya se dibujó —
  // condición real (el widget tree y sus Providers ya existen), no un delay
  // arbitrario adivinado. `restorePlaybackState` es idempotente por estado
  // real (ver MusicProvider), así que no depende de correr en un momento exacto.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    musicProvider.restorePlaybackState(audioHandler);
  });
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
