import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/database_helper.dart';
import '../services/download_service.dart';
import '../services/download_source.dart';

/// Un trabajo pendiente, tal como lo ve la UI.
class DownloadJob {
  final int queueId;
  final String sourceType;
  final String sourceId;
  final String sourceUrl;
  final String playlistId;
  final String title;
  final String artist;
  final String? album;
  final int durationSeconds;
  final String thumbnailUrl;
  final int? expectedOrderIndex;
  final int attempts;

  /// False mientras la metadata venga de `extract_flat` (búsqueda o expansión
  /// de playlist), donde `artist` es en realidad el nombre del canal.
  final bool metadataComplete;

  const DownloadJob({
    required this.queueId,
    required this.sourceType,
    required this.sourceId,
    required this.sourceUrl,
    required this.playlistId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    required this.thumbnailUrl,
    required this.expectedOrderIndex,
    required this.attempts,
    required this.metadataComplete,
  });

  factory DownloadJob.fromRow(Map<String, dynamic> row) {
    final id = (row['sourceId'] ?? '').toString();
    return DownloadJob(
      queueId: row['id'] as int,
      sourceType: (row['sourceType'] ?? 'youtube').toString(),
      sourceId: id,
      sourceUrl: (row['sourceUrl'] ?? '').toString(),
      playlistId: (row['playlistId'] ?? '').toString(),
      title: (row['title'] ?? '').toString(),
      artist: (row['artist'] ?? '').toString(),
      album: row['album'] as String?,
      durationSeconds: (row['durationSeconds'] as int?) ?? 0,
      thumbnailUrl: (row['thumbnailUrl'] ?? '').toString(),
      expectedOrderIndex: row['expectedOrderIndex'] as int?,
      attempts: (row['attempts'] as int?) ?? 0,
      metadataComplete: ((row['metadataComplete'] as int?) ?? 0) != 0,
    );
  }

  RemoteTrack toRemoteTrack() => RemoteTrack(
        id: sourceId,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
        thumbnailUrl: thumbnailUrl,
        sourceUrl: sourceUrl,
      );

  String get displayTitle => title.isEmpty ? sourceId : title;
}

/// Un trabajo que se dio por perdido, para que la UI pueda contarlo.
class DownloadFailure {
  final String title;
  final String message;

  /// True si el vídeo no va a poder descargarse nunca (borrado, privado, sin
  /// pista AAC). False si simplemente se agotaron los reintentos.
  final bool permanent;
  final DateTime at;

  const DownloadFailure({
    required this.title,
    required this.message,
    required this.permanent,
    required this.at,
  });
}

/// En qué está el trabajo actual. La UI lo necesita porque `/audio` bloquea
/// mientras el servidor baja el vídeo: durante esos segundos no hay progreso
/// por bytes que enseñar, y una barra parada parece un cuelgue.
enum DownloadPhase { idle, resolving, preparing, downloading, saving }

/// Orquesta la cola persistente de descargas.
///
/// **Decide qué descargar y cuándo; el cómo es de [DownloadService].** No
/// conoce el servidor ni HTTP: todo pasa por [DownloadSource]. Cambiar de
/// proveedor no debería obligar a tocar este archivo.
class DownloadProvider extends ChangeNotifier {
  /// Presupuesto duro por trabajo. Vive en la base (`download_queue.attempts`)
  /// y no en memoria, para que reiniciar la app no lo regale.
  static const int maxAttempts = 3;

  /// Uno solo, deliberadamente. El muro de YouTube es un presupuesto
  /// acumulado por IP, no un límite de tasa: la concurrencia lo gasta más
  /// rápido sin dar throughput real. Ver docs/investigacion_muro_antibot.md.
  static const int maxConcurrent = 1;

  static const List<Duration> _backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  final DownloadService _service;
  final DatabaseHelper _db;

  /// Se llama tras cada descarga con éxito. Es cómo la biblioteca se entera,
  /// sin que este provider tenga que conocer a MusicProvider.
  final Future<void> Function(String playlistId)? onDownloadComplete;

  DownloadProvider({
    required DownloadService service,
    DatabaseHelper? db,
    this.onDownloadComplete,
  })  : _service = service,
        _db = db ?? DatabaseHelper.instance;

  List<DownloadJob> _queue = const [];
  final List<DownloadFailure> _failures = [];
  DownloadJob? _current;
  DownloadPhase _phase = DownloadPhase.idle;
  double _progress = 0;
  bool _isProcessing = false;
  bool _cancelRequested = false;

  /// Cada worker captura el valor al empezar; si cambia, es que hubo una
  /// cancelación y el worker debe abandonar en vez de escribir en la
  /// biblioteca resultados de una tanda que el usuario ya dio por muerta.
  int _sessionId = 0;

  /// Backoff sólo en memoria, a propósito: el contador duro de intentos ya
  /// está en la base. Perder el backoff al reiniciar es lo deseable — si el
  /// usuario reabre la app, quiere que se reintente ya.
  final Map<int, DateTime> _retryAfter = {};

  /// Programa la siguiente pasada cuando sólo quedan trabajos esperando su
  /// backoff. Ver [processQueue] para por qué no se duerme dentro del bucle.
  Timer? _retryTimer;

  List<DownloadJob> get queue => List.unmodifiable(_queue);
  List<DownloadFailure> get failures => List.unmodifiable(_failures);
  DownloadJob? get current => _current;
  DownloadPhase get phase => _phase;
  bool get isProcessing => _isProcessing;
  int get pendingCount => _queue.length;

  /// 0..1 durante la transferencia. **-1 significa indeterminado**: el
  /// servidor está bajando el vídeo y todavía no hay bytes que contar.
  double get progress => _progress;

  String get phaseLabel => switch (_phase) {
        DownloadPhase.idle => '',
        DownloadPhase.resolving => 'Obteniendo datos…',
        DownloadPhase.preparing => 'Preparando en el servidor…',
        DownloadPhase.downloading => 'Descargando…',
        DownloadPhase.saving => 'Guardando en la biblioteca…',
      };

  // --- Encolar ---

  /// Encola una pista. [metadataComplete] debe ser true sólo si [track] viene
  /// de `/resolve`; false para resultados de búsqueda y entradas de playlist.
  Future<bool> enqueueTrack(
    RemoteTrack track, {
    required String playlistId,
    required bool metadataComplete,
    String sourceType = 'youtube',
    int? expectedOrderIndex,
  }) async {
    final added = await _db.enqueueDownload(
      sourceType: sourceType,
      sourceId: track.id,
      sourceUrl: track.sourceUrl,
      playlistId: playlistId,
      title: track.title,
      artist: track.artist,
      album: track.album,
      durationSeconds: track.durationSeconds,
      thumbnailUrl: track.thumbnailUrl,
      expectedOrderIndex: expectedOrderIndex,
      metadataComplete: metadataComplete,
    );
    await refreshQueue();
    return added;
  }

  /// Encola una playlist entera preservando su orden.
  ///
  /// Las entradas vienen de `extract_flat`, así que ninguna tiene metadata
  /// definitiva y todas pasarán por `/resolve` antes de bajarse.
  Future<int> enqueuePlaylist(
    RemotePlaylist playlist, {
    required String playlistId,
  }) async {
    var added = 0;
    for (var i = 0; i < playlist.entries.length; i++) {
      final entry = playlist.entries[i];
      final ok = await _db.enqueueDownload(
        sourceType: 'youtube',
        sourceId: entry.id,
        sourceUrl: entry.sourceUrl,
        playlistId: playlistId,
        title: entry.title,
        artist: entry.artist,
        album: entry.album,
        durationSeconds: entry.durationSeconds,
        thumbnailUrl: entry.thumbnailUrl,
        expectedOrderIndex: i,
        metadataComplete: false,
      );
      if (ok) added++;
    }
    await refreshQueue();
    return added;
  }

  Future<void> refreshQueue() async {
    final rows = await _db.getDownloadQueue();
    _queue = rows.map(DownloadJob.fromRow).toList();
    notifyListeners();
  }

  // --- Cancelar ---

  /// Cancela la tanda entera y vacía la cola.
  Future<void> cancelAll() async {
    _cancelRequested = true;
    _sessionId++;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _db.clearDownloadQueue();
    _retryAfter.clear();
    await refreshQueue();
    // No se espera a que el worker en curso termine: comprueba `_isStale` en
    // cada paso y abandonará solo. Bloquear aquí congelaría la UI durante la
    // transferencia que se acaba de cancelar.
  }

  Future<void> cancelJob(int queueId) async {
    if (_current?.queueId == queueId) {
      _cancelRequested = true;
      _sessionId++;
    }
    await _db.removeFromDownloadQueue(queueId);
    _retryAfter.remove(queueId);
    await refreshQueue();
  }

  Future<void> cancelPlaylist(String playlistId) async {
    if (_current?.playlistId == playlistId) {
      _cancelRequested = true;
      _sessionId++;
    }
    await _db.clearDownloadQueueForPlaylist(playlistId);
    await refreshQueue();
  }

  void clearFailures() {
    _failures.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    super.dispose();
  }

  // --- Procesar ---

  /// Procesa **lo que se puede procesar ahora**, uno cada vez, y vuelve.
  ///
  /// Los trabajos que están esperando su backoff no se esperan dentro del
  /// bucle: se programa un temporizador que vuelve a llamar aquí cuando toque.
  /// Dormir dentro del bucle dejaría `isProcessing` en true durante hasta 45
  /// segundos sin que pase nada —la UI diría "descargando" con todo parado— y
  /// haría que `cancelAll` no pudiera interrumpir el `Future.delayed`.
  ///
  /// Es seguro llamarlo de más: si ya hay un bucle andando, no hace nada.
  Future<void> processQueue() async {
    if (_isProcessing) return;
    _isProcessing = true;
    _cancelRequested = false;
    final sessionId = _sessionId;
    _retryTimer?.cancel();
    _retryTimer = null;
    notifyListeners();

    try {
      while (true) {
        if (_isStale(sessionId)) break;

        await refreshQueue();
        final job = _nextRunnable();
        if (job == null) break;

        await _runJob(job, sessionId);
      }
    } finally {
      // Un único finally: con varias salidas tempranas, resetear en cada una
      // es exactamente cómo se acaba con la UI bloqueada en un camino que
      // nadie probó.
      _isProcessing = false;
      _current = null;
      _phase = DownloadPhase.idle;
      _progress = 0;
      if (!_cancelRequested && sessionId == _sessionId) _scheduleRetryPass();
      notifyListeners();
    }
  }

  /// Programa otra pasada para cuando venza el backoff más próximo.
  void _scheduleRetryPass() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final wait = _shortestWait();
    if (wait == null) return;
    _retryTimer = Timer(wait, () {
      _retryTimer = null;
      processQueue();
    });
  }

  bool _isStale(int sessionId) => _cancelRequested || sessionId != _sessionId;

  DownloadJob? _nextRunnable() {
    final now = DateTime.now();
    for (final job in _queue) {
      final after = _retryAfter[job.queueId];
      if (after != null && after.isAfter(now)) continue;
      return job;
    }
    return null;
  }

  Duration? _shortestWait() {
    final now = DateTime.now();
    Duration? shortest;
    for (final job in _queue) {
      final after = _retryAfter[job.queueId];
      if (after == null || !after.isAfter(now)) continue;
      final wait = after.difference(now);
      if (shortest == null || wait < shortest) shortest = wait;
    }
    return shortest;
  }

  Future<void> _runJob(DownloadJob job, int sessionId) async {
    _current = job;
    _phase = job.metadataComplete ? DownloadPhase.preparing : DownloadPhase.resolving;
    _progress = -1;
    notifyListeners();

    // La playlist destino puede haber desaparecido mientras el trabajo
    // esperaba: la cola no tiene FK a propósito, para que eso falle como un
    // trabajo y no se lleve la tanda por delante en cascada.
    if (await _db.getPlaylistById(job.playlistId) == null) {
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, 'La playlist de destino ya no existe', permanent: true);
      return;
    }

    try {
      final result = await _service.download(
        job.toRemoteTrack(),
        playlistId: job.playlistId,
        resolveFirst: !job.metadataComplete,
        onResolved: (resolved) async {
          // Se persiste ANTES de bajar un byte: si la descarga falla y el
          // trabajo se reintenta, el resolve no se repite.
          await _db.markDownloadMetadataResolved(
            job.queueId,
            sourceId: resolved.id,
            title: resolved.title,
            artist: resolved.artist,
            album: resolved.album,
            durationSeconds: resolved.durationSeconds,
            thumbnailUrl: resolved.thumbnailUrl,
            sourceUrl: resolved.sourceUrl.isEmpty ? null : resolved.sourceUrl,
          );
          if (_isStale(sessionId)) return;
          _phase = DownloadPhase.preparing;
          _current = job;
          notifyListeners();
        },
        onProgress: (received, total) {
          if (_isStale(sessionId)) return;
          _phase = DownloadPhase.downloading;
          _progress = (total == null || total <= 0) ? -1 : received / total;
          notifyListeners();
        },
        isCancelled: () => _isStale(sessionId),
      );

      if (_isStale(sessionId)) return;

      _phase = DownloadPhase.saving;
      notifyListeners();

      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      await onDownloadComplete?.call(job.playlistId);

      if (result.outcome == DownloadOutcome.alreadyInLibrary) {
        // No es un fallo, pero merece decirlo: el usuario pidió N canciones y
        // en la playlist aparecerán N aunque alguna no se haya bajado.
        debugPrint(
          'DownloadProvider: "${result.track.title}" ya estaba en la biblioteca, '
          'sólo se añadió a la playlist',
        );
      }
    } on DownloadSourceException catch (e) {
      if (_isStale(sessionId)) return;
      await _handleFailure(job, e);
    } catch (e) {
      if (_isStale(sessionId)) return;
      // Cualquier cosa inesperada se trata como reintentable: es preferible
      // gastar dos intentos de más que descartar en silencio una canción por
      // un fallo que nadie previó.
      await _handleFailure(
        job,
        DownloadSourceException(DownloadSourceErrorKind.extraction, e.toString()),
      );
    }
  }

  Future<void> _handleFailure(DownloadJob job, DownloadSourceException error) async {
    if (error.kind == DownloadSourceErrorKind.cancelled) return;

    // Un fallo definitivo sale de la cola en el primer intento. Gastar tres
    // reintentos en un vídeo borrado es tiempo y presupuesto de IP tirados, y
    // encima retrasa las canciones que sí se pueden bajar.
    if (!error.isRetryable) {
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, error.userMessage, permanent: true);
      return;
    }

    await _db.markDownloadAttempt(job.queueId, error.message);
    final attempts = job.attempts + 1;

    if (attempts >= maxAttempts) {
      await _db.removeFromDownloadQueue(job.queueId);
      _retryAfter.remove(job.queueId);
      _recordFailure(job, error.userMessage, permanent: false);
      return;
    }

    final delay = _backoff[(attempts - 1).clamp(0, _backoff.length - 1)];
    _retryAfter[job.queueId] = DateTime.now().add(delay);
    await refreshQueue();
  }

  void _recordFailure(DownloadJob job, String message, {required bool permanent}) {
    _failures.insert(
      0,
      DownloadFailure(
        title: job.displayTitle,
        message: message,
        permanent: permanent,
        at: DateTime.now(),
      ),
    );
    // Acotado: es un registro para enseñar, no un log.
    if (_failures.length > 50) _failures.removeRange(50, _failures.length);
    notifyListeners();
  }
}
