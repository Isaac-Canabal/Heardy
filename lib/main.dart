import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:audio_service/audio_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:firebase_core/firebase_core.dart';

import 'services/database_helper.dart';
import 'services/audio_player_handler.dart';
import 'services/cloud_source.dart';
import 'services/download_service.dart';
import 'services/download_source.dart';
import 'services/heardy_cloud_source.dart';
import 'services/ytdlp_server_source.dart';
import 'providers/auth_provider.dart';
import 'providers/download_provider.dart';
import 'providers/music_provider.dart';
import 'providers/settings_provider.dart';
import 'providers/sync_provider.dart';
import 'screens/main_shell_screen.dart';
import 'screens/playlist_detail_screen.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Requisito de flutter_foreground_task para poder mandar/recibir datos
  // entre el isolate del servicio y la UI — no se usa ese canal acá (el
  // TaskHandler de descargas no hace nada por sí mismo, ver
  // download_foreground_service.dart), pero hay que llamarlo igual antes de
  // arrancar cualquier servicio.
  FlutterForegroundTask.initCommunicationPort();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await DatabaseHelper.instance.database;

  // Fase 2 del plan de seguridad: identidad por cuenta real (Firebase Auth)
  // en vez de la clave de API única compilada en el binario. Sin opciones
  // explícitas: app Android-only, `android/app/google-services.json` (vía el
  // plugin de Gradle) ya deja todo lo que el SDK necesita.
  await Firebase.initializeApp();

  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
  );
  // A fresh instance is enough: flutter_local_notifications initializes the
  // plugin platform-wide, so any other instance (e.g. AudioPlayerHandler's
  // own for playback-error notifications) shares this same initialization.
  await FlutterLocalNotificationsPlugin().initialize(initializationSettings);

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
  final settingsProvider = SettingsProvider();
  final authProvider = HeardyAuthProvider();

  // La fuente lee la configuración por closures, no por copia: cambiar la
  // dirección en Ajustes (o iniciar/cerrar sesión) tiene efecto inmediato,
  // sin reconstruir nada ni reiniciar la app. `authToken` reemplaza la clave
  // de API fija de antes (Fase 2 del plan de seguridad, cierra A1): sin
  // sesión, devuelve null y la llamada sale sin autenticar.
  final DownloadSource downloadSource = YtdlpServerSource(
    baseUrl: () => settingsProvider.downloadServerUrl,
    authToken: () => authProvider.idToken(),
  );
  final downloadProvider = DownloadProvider(
    service: DownloadService(source: downloadSource),
    source: downloadSource,
    // Así se entera la biblioteca de una descarga nueva sin que
    // DownloadProvider tenga que conocer a MusicProvider.
    onDownloadComplete: (playlistId) async {
      await musicProvider.loadPlaylists();
      await musicProvider.loadSongsForPlaylist(
        playlistId,
        updateCurrent: musicProvider.currentPlaylistId == playlistId,
      );
      await musicProvider.refreshInboxCount();
      musicProvider.notifyLibraryChanged();
    },
  );

  // Misma base/autenticación que el servidor de descargas — una sola
  // instancia del servidor, dos superficies (`DownloadSource`, `CloudSource`).
  final CloudSource cloudSource = HeardyCloudSource(
    baseUrl: () => settingsProvider.downloadServerUrl,
    authToken: () => authProvider.idToken(),
  );
  final syncProvider = SyncProvider(
    source: cloudSource,
    shareNowPlayingEnabled: () => settingsProvider.shareNowPlaying,
  );
  syncProvider.attachPlayback(audioHandler);

  runApp(
    MultiProvider(
      providers: [
        Provider<AudioPlayerHandler>.value(value: audioHandler),
        Provider<DownloadSource>.value(value: downloadSource),
        Provider<CloudSource>.value(value: cloudSource),
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider.value(value: settingsProvider),
        ChangeNotifierProvider.value(value: musicProvider),
        ChangeNotifierProvider.value(value: downloadProvider),
        ChangeNotifierProvider.value(value: syncProvider),
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
    // Retoma una tanda que quedó a medias porque el proceso murió. La cola
    // vive en SQLite justamente para esto; si está vacía, processQueue sale
    // enseguida sin hacer nada.
    downloadProvider.processQueue();
    // El servidor oficial vive en un PC de casa, no siempre encendido: cada
    // arranque en frío es una oportunidad razonable de comprobar si ya volvió
    // y resolver solo lo que quedó en la lista de espera.
    downloadProvider.retryPendingImports();
    // Nunca `await`ado: un refresco de token de Firebase en el camino de
    // arranque no puede retrasar el primer fotograma ni la restauración de
    // la reproducción. Sin sesión, syncNow() falla con `unauthorized`
    // (capturado dentro del propio provider) y no hace nada más.
    syncProvider.syncNow();
  });
}

class HeardyApp extends StatelessWidget {
  const HeardyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, _) {
        AppTheme.applyPreset(settings.preset);
        AppTheme.applyCustomColors(
          primary: settings.customPrimary,
          secondary: settings.customSecondary,
          combined: settings.customCombined,
        );
        return MaterialApp(
          title: 'Heardy',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(),
          locale: settings.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
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
