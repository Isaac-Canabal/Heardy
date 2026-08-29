import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../services/audio_player_handler.dart';
import '../services/cloud_source.dart';
import '../services/database_helper.dart';

/// Sincronización de cuenta (Etapa 16): índice de biblioteca + historial de
/// reproducción hacia el servidor. Misma forma que `DownloadProvider`: recibe
/// su servicio ([CloudSource]) y no sostiene otros providers — así queda
/// testeable con un doble y es un orquestador puro.
///
/// **Disparadores, todos señales reales, cero polling** (ver CLAUDE.md,
/// "Cloud sync"): arranque en frío, `AppLifecycleState.resumed` con
/// estrangulamiento, justo tras vincular/iniciar sesión, y el botón
/// "Sincronizar ahora".
///
/// **Simplificación deliberada frente al plan original:** en vez de un flag
/// `markLibraryDirty()` que cada punto de mutación de la biblioteca tendría
/// que llamar, este provider calcula un hash de contenido LOCAL antes de
/// cada intento de subida y sólo llama a la red si cambió desde la última
/// subida exitosa — el mismo atajo por `contentHash` que ya existe del lado
/// del servidor (ver `server/app/main.py:put_library`), aplicado también acá
/// para no depender de instrumentar cada sitio que cambia la biblioteca.
class SyncProvider with ChangeNotifier {
  final CloudSource _source;
  final DatabaseHelper _db;

  bool _isSyncing = false;
  DateTime? _lastSyncAt;
  String? _lastError;
  CloudAccount? _account;
  int _libraryVersion = 0;
  String? _lastPushedContentHash;
  DateTime? _lastResumeSync;

  // --- "Escuchando ahora" (F8) ---
  final bool Function() _shareEnabled;
  StreamSubscription? _mediaItemSub;
  StreamSubscription<bool>? _playingSub;
  Timer? _minListenTimer;
  String? _currentSongId;
  Duration? _currentDuration;
  bool _currentlyPlaying = false;
  DateTime? _songStartedAt;
  DateTime? _lastPublishAt;
  String? _lastPublishedSongId;

  /// Una canción no se publica hasta llevar esto sonando — los saltos nunca
  /// llegan a la red.
  static const _minListenSeconds = 20;

  /// Mínimo entre dos peticiones de presencia — un cambio dentro de la
  /// ventana se agrupa (el `Timer` de [_minListenTimer] ya cumple ese papel
  /// al reprogramarse por canción), nunca se manda de más.
  static const _publishThrottle = Duration(seconds: 30);

  SyncProvider({
    required CloudSource source,
    DatabaseHelper? db,
    bool Function()? shareNowPlayingEnabled,
  })  : _source = source,
        _db = db ?? DatabaseHelper.instance,
        _shareEnabled = shareNowPlayingEnabled ?? (() => false);

  bool get isSyncing => _isSyncing;
  DateTime? get lastSyncAt => _lastSyncAt;
  String? get lastError => _lastError;
  CloudAccount? get account => _account;

  /// Actualiza el nombre de usuario cacheado al instante, sin esperar la
  /// próxima `syncNow()`. **El bug que esto corrige:** `ensureUsername`
  /// guarda el nombre contra el servidor directamente (no pasa por acá), así
  /// que hasta ahora la sección de Cuenta seguía mostrando "todavía no
  /// elegiste un nombre" — porque `_account` sólo se refrescaba en la
  /// siguiente pasada completa de `syncNow()`, y si esa pasada fallaba por
  /// cualquier otra razón (la biblioteca, el historial, la red), la UI daba
  /// la impresión de que el nombre nunca se había guardado. El nombre SÍ
  /// queda guardado en el servidor en cuanto `setUsername` responde 200 —
  /// esto sólo corrige que el cliente se entere sin depender de una
  /// sincronización completa y ajena.
  void noteUsernameSaved(String username) {
    final current = _account;
    _account = CloudAccount(
      identity: current?.identity ?? '',
      username: username,
      libraryVersion: current?.libraryVersion ?? _libraryVersion,
      hasLibrary: current?.hasLibrary ?? false,
      friendCount: current?.friendCount ?? 0,
    );
    notifyListeners();
  }

  /// Estrangula `resumed`: se dispara al volver de segundo plano, pero no si
  /// ya se sincronizó hace menos de 15 minutos — `resumed` ocurre cada vez
  /// que se vuelve de WhatsApp, no cada vez que hace falta revisar la nube.
  static const _resumeThrottle = Duration(minutes: 15);

  Future<void> onAppResumed() async {
    final last = _lastResumeSync;
    if (last != null && DateTime.now().difference(last) < _resumeThrottle) return;
    _lastResumeSync = DateTime.now();
    await syncNow();
  }

  /// Orden de una pasada: `GET /account` → subir historial pendiente en
  /// lotes de ≤500 → si el contenido cambió, `PUT /library`. Para al primer
  /// fallo de RED (misma semántica que `retryPendingImports()`), no ante
  /// otros errores (409, 428) que se dejan como estado visible en
  /// [lastError] en vez de reintentarse solos.
  Future<void> syncNow() async {
    if (_isSyncing) return;
    _isSyncing = true;
    _lastError = null;
    notifyListeners();
    try {
      _account = await _source.getAccount();
      _libraryVersion = _account!.libraryVersion;

      await _pushUnsyncedHistory();
      await _pushLibraryIfChanged();

      _lastSyncAt = DateTime.now();
    } on CloudSourceException catch (e) {
      _lastError = e.message;
      if (e.kind == CloudSourceErrorKind.network) {
        // Nada más que hacer esta pasada: sin conexión, cualquier otra
        // llamada fallaría igual.
      }
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> _pushUnsyncedHistory() async {
    final offset = DateTime.now().timeZoneOffset.inMinutes;
    while (true) {
      final rows = await _db.getUnsyncedPlays(limit: 500);
      if (rows.isEmpty) return;

      final orphanIds = <int>[];
      final payloadIds = <int>[];
      final payload = <Map<String, dynamic>>[];
      for (final row in rows) {
        final id = row['id'] as int;
        if (row['existingSongId'] == null) {
          orphanIds.add(id);
          continue;
        }
        final playedAtUtc = (row['playedAtUtc'] as String?) ??
            DateTime.parse(row['playDate'] as String).toUtc().toIso8601String();
        payloadIds.add(id);
        payload.add({
          'songId': row['songId'],
          'playedAtLocal': row['playDate'],
          'playedAtUtc': playedAtUtc,
          'playSeconds': row['playDuration'] ?? 0,
        });
      }

      if (orphanIds.isNotEmpty) await _db.markPlaysSkipped(orphanIds);
      if (payload.isNotEmpty) {
        await _source.pushHistory(payload, utcOffsetMinutes: offset);
        // Si la llamada de arriba no lanzó, el servidor ya tomó una decisión
        // final sobre cada fila (aceptada o descartada por vieja) — marcar
        // todo el lote sincronizado, no sólo lo "stored", es correcto: no
        // hay nada que reintentar para una fila que el servidor ya vio.
        await _db.markPlaysSynced(payloadIds);
      }

      if (rows.length < 500) return;
    }
  }

  Future<void> _pushLibraryIfChanged() async {
    final index = await _db.getLibraryIndexRows();
    final contentHash = _hashOf(index);
    if (contentHash == _lastPushedContentHash) return;

    final newVersion = await _source.pushLibrary(
      baseVersion: _libraryVersion,
      contentHash: contentHash,
      songs: index['songs']!,
      playlists: index['playlists']!,
      playlistSongs: index['playlistSongs']!,
    );
    _libraryVersion = newVersion;
    _lastPushedContentHash = contentHash;
  }

  String _hashOf(Map<String, List<Map<String, dynamic>>> index) {
    // Orden estable antes de hashear: el mismo contenido en otro orden de
    // filas no debe verse como "cambió".
    final songs = [...index['songs']!]..sort((a, b) => '${a['songId']}'.compareTo('${b['songId']}'));
    final playlists = [...index['playlists']!]..sort((a, b) => '${a['playlistId']}'.compareTo('${b['playlistId']}'));
    final playlistSongs = [...index['playlistSongs']!]
      ..sort((a, b) => '${a['playlistId']}${a['songId']}'.compareTo('${b['playlistId']}${b['songId']}'));
    final bytes = utf8.encode(jsonEncode({'s': songs, 'p': playlists, 'ps': playlistSongs}));
    return md5.convert(bytes).toString();
  }

  /// Se suscribe a los streams que `AudioPlayerHandler` YA expone — nunca se
  /// toca ese archivo (~1000 líneas con historial de bugs sutiles y sin
  /// doble de prueba para `just_audio`; cero ediciones ahí = cero riesgo de
  /// romper la reproducción, ver CLAUDE.md). Idempotente: llamar más de una
  /// vez cancela las suscripciones previas primero.
  void attachPlayback(AudioPlayerHandler handler) {
    _mediaItemSub?.cancel();
    _playingSub?.cancel();
    _mediaItemSub = handler.mediaItem.distinct((a, b) => a?.id == b?.id).listen((item) {
      _currentSongId = item?.id;
      _currentDuration = item?.duration;
      _songStartedAt = DateTime.now();
      if (_currentlyPlaying && _currentSongId != null) _scheduleMinListenCheck();
    });
    _playingSub = handler.playbackState.map((s) => s.playing).distinct().listen((playing) {
      _currentlyPlaying = playing;
      if (playing) {
        _songStartedAt ??= DateTime.now();
        if (_currentSongId != null) _scheduleMinListenCheck();
      } else {
        _minListenTimer?.cancel();
        _clearPresence();
      }
    });
  }

  void _scheduleMinListenCheck() {
    _minListenTimer?.cancel();
    _minListenTimer = Timer(const Duration(seconds: _minListenSeconds), _maybePublishPresence);
  }

  void _maybePublishPresence() {
    if (!_shareEnabled() || !_currentlyPlaying) return;
    // Nunca un temporizador de latido: si nadie puede verla, publicar es
    // batería y datos tirados por nada.
    if ((_account?.friendCount ?? 0) <= 0) return;
    final songId = _currentSongId;
    final startedAt = _songStartedAt;
    if (songId == null || startedAt == null) return;

    final now = DateTime.now();
    if (songId == _lastPublishedSongId &&
        _lastPublishAt != null &&
        now.difference(_lastPublishAt!) < _publishThrottle) {
      return;
    }

    final elapsedSeconds = now.difference(startedAt).inSeconds;
    final duration = _currentDuration;
    // El TTL lo calcula el cliente: lo que le queda a la canción + 60s, así
    // la presencia caduca EXACTAMENTE cuando la canción habría terminado —
    // nunca un temporizador de "adiós" que Android podría no llegar a correr.
    final remaining = duration != null ? (duration.inSeconds - elapsedSeconds).clamp(0, 3600) : 180;
    final ttl = remaining + 60;

    _lastPublishAt = now;
    _lastPublishedSongId = songId;
    unawaited(_source.putPresence(songId: songId, expiresInSeconds: ttl).catchError((_) {}));
  }

  void _clearPresence() {
    if (_lastPublishedSongId == null) return;
    _lastPublishedSongId = null;
    unawaited(_source.clearPresence().catchError((_) {}));
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    _playingSub?.cancel();
    _minListenTimer?.cancel();
    super.dispose();
  }

  /// La válvula de escape de privacidad: borra biblioteca/historial/
  /// amistades de la cuenta en el servidor, y resetea las marcas locales de
  /// `syncedAt` para que un revínculo posterior resuba todo desde cero.
  Future<void> deleteCloudData() async {
    await _source.deleteAccountData();
    await _db.resetHistorySyncMarkers();
    _lastPushedContentHash = null;
    _libraryVersion = 0;
    _lastSyncAt = null;
    notifyListeners();
  }
}
