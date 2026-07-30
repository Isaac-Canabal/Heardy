import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:meta/meta.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Metadata from "Analizar enlace" — no stream URLs (those expire / are single-use).
class _CachedVideoMetadata {
  final String title;
  final String artist;
  final Duration duration;
  final String thumbnailUrl;
  final DateTime cachedAt;

  static const _maxAge = Duration(minutes: 30);

  const _CachedVideoMetadata({
    required this.title,
    required this.artist,
    required this.duration,
    required this.thumbnailUrl,
    required this.cachedAt,
  });

  bool get isValid => DateTime.now().difference(cachedAt) < _maxAge;
}

/// Resultado de búsqueda de YouTube
class YouTubeSearchResult {
  final String videoId;
  final String title;
  final String artist;
  final Duration duration;
  final String thumbnailUrl;
  final String url;

  const YouTubeSearchResult({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.duration,
    required this.thumbnailUrl,
    required this.url,
  });
}

/// El muro anti-bot de YouTube, como TIPO.
///
/// Existe para que el corte temprano no dependa de volver a hacer match por
/// subcadena en cada capa — que es justo el acoplamiento frágil que ya sufre
/// `_isRetryableError`, donde `VideoUnplayableException` se clasifica como
/// reintentable de rebote, porque su mensaje contiene la palabra "Streams".
///
/// Conserva el error original en `toString()` a propósito: `_isHardBlockError`,
/// `LogService` y el log de errores siguen viendo el texto completo de YouTube.
class BotWallException implements Exception {
  BotWallException(this.original);

  final Object original;

  @override
  String toString() => 'BotWallException: $original';
}

/// Un chunk a mitad de descarga (no el primero — ver `_downloadSequential`)
/// respondió con un status ≠ 200/206.
///
/// Existe para que ese modo de fallo sea DIAGNOSTICABLE la próxima vez que
/// ocurra, no para arreglarlo — hasta ahora nunca se observó un caso real, sólo
/// el corte al inicio (chunk 0, cubierto por el fallback sin Range y el
/// `streamHttpErrorMarker`). A propósito NO lleva ese marcador ni dispara el
/// salto de cliente de `downloadVideoWithAudio`: un corte a mitad puede ser el
/// mismo cliente-condenado del 403-al-inicio (Test A/B,
/// docs/investigacion_muro_antibot.md), pero también puede ser la URL de
/// stream expirando de verdad a mitad de una descarga larga — un fenómeno
/// distinto cuya solución es la opuesta (pedir un manifest nuevo SÍ sirve ahí,
/// saltar de cliente no tiene por qué). El primer caso real que capture esto
/// dice, por el `statusCode`, cuál de las dos hipótesis es: 403/401 apunta a
/// cliente-condenado, 410/otro apunta a expiración real.
class MidDownloadCutException implements Exception {
  MidDownloadCutException({
    required this.statusCode,
    required this.chunkIndex,
    required this.bytesReceived,
    required this.totalBytes,
    required this.manifestClientIndex,
    required this.manifestClientNames,
  });

  final int statusCode;
  final int chunkIndex;
  final int bytesReceived;
  final int totalBytes;
  final int? manifestClientIndex;
  final String? manifestClientNames;

  @override
  String toString() =>
      'MidDownloadCutException: HTTP $statusCode en el chunk $chunkIndex '
      '($bytesReceived/$totalBytes bytes recibidos antes del corte), '
      'cliente de manifest #$manifestClientIndex ($manifestClientNames)';
}

class YoutubeService {
  YoutubeService();

  static final Map<String, _CachedVideoMetadata> _metadataCache = {};

  /// Lets a caller (namely `YTMusicService`) prime the metadata cache from a
  /// source other than this class's own `videos.get()` — which, in this
  /// youtube_explode_dart version, ALWAYS scrapes the raw `/watch` page HTML
  /// and infers availability from the presence of a `<meta property="og:url">`
  /// tag (see `WatchPage.isVideoAvailable`). That page is the one YouTube
  /// serves a "sign in to confirm you're not a bot" wall on under load,
  /// causing false VideoUnavailableException for videos that play back fine
  /// everywhere else. `dart_ytmusic_api`'s `getSong()` hits YouTube's
  /// structured InnerTube `player` JSON endpoint instead and isn't gated by
  /// that same wall. When it succeeds, priming the cache here makes
  /// `downloadVideoWithAudio`/`getVideoInfo` skip the scrape entirely (they
  /// both check this cache before calling `_getVideoWithFallback`).
  static void primeMetadataCache(
    String videoId, {
    required String title,
    required String artist,
    required Duration duration,
    required String thumbnailUrl,
  }) {
    _metadataCache[videoId] = _CachedVideoMetadata(
      title: title,
      artist: artist,
      duration: duration,
      thumbnailUrl: thumbnailUrl,
      cachedAt: DateTime.now(),
    );
  }

  /// Convierte enlaces de YouTube Music a enlaces estándar de YouTube
  /// YouTube Music usa el mismo sistema de IDs, solo cambia el dominio
  static String _convertYouTubeMusicUrl(String url) {
    if (url.contains('music.youtube.com')) {
      return url.replaceAll('music.youtube.com', 'www.youtube.com');
    }
    return url;
  }

  /// Ordered list of Android client combinations to try when fetching the stream manifest.
  /// YouTube periodically blocks certain clients, so we cascade through these.
  /// NOTE: ytClients is only supported by streamsClient.getManifest(), NOT videos.get().
  /// CORRECCIÓN: aquí se afirmaba que `androidVr` "falla el 100% de las veces",
  /// medido 6/6. Es falso — `tool/client_sweep_probe.dart` barre los 11 clientes
  /// que expone la librería y `androidVr` sirve bytes igual que `android`,
  /// `androidSdkless` e `ios`. Aquella tanda de 6/6 midió una sesión ya
  /// bloqueada, no al cliente.
  ///
  /// Aquella cascada se quedaba en DOS clientes a propósito porque el barrido
  /// demuestra que añadir más no ayuda contra el bloqueo de SESIÓN: cuando
  /// YouTube bloquea, bloquea la sesión entera, y los 11 clientes fallan a la
  /// vez en la misma corrida. Ese razonamiento sigue siendo cierto — pero es
  /// sobre un modo de fallo distinto al que motiva el orden de abajo.
  ///
  /// `[androidVr, safari]` va PRIMERO ahora, no por el bloqueo de sesión sino
  /// por el modo de fallo separado descrito en `_streamUserAgent` y
  /// `docs/investigacion_muro_antibot.md` (Test A/B, 2026-07-29): con manifest
  /// sano, `android`/`androidSdkless` pueden devolver URLs de stream que dan
  /// 403 determinista al pedir los BYTES con el UA de navegador que usa esta
  /// app — no es un problema de UA desajustado sino del cliente que resolvió
  /// el manifest. `[androidVr, safari]`, la combinación de `main`, no lo
  /// reproduce (2/2 en Test B, mismos vídeos, mismo UA, único cambio: el
  /// cliente). `android`/`androidSdkless` NO se eliminan — quedan como último
  /// recurso, porque no está medido que `androidVr`/`safari` cubran el 100% de
  /// los vídeos (podría haber vídeos donde sea al revés).
  static final List<List<YoutubeApiClient>> _clientFallbacks = [
    [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
    [YoutubeApiClient.android],
    [YoutubeApiClient.androidSdkless],
    [YoutubeApiClient.android, YoutubeApiClient.androidSdkless],
  ];

  /// Copia de `_clientFallbacks`, en orden. Para que un test de tabla verifique
  /// el orden de la cascada (`[androidVr, safari]` primero) sin depender de un
  /// símbolo privado. Los objetos son los mismos `const YoutubeApiClient.*`
  /// que usa la cascada real, así que un test puede compararlos por identidad
  /// en vez de por `clientName` — `android` y `androidSdkless` declaran el
  /// mismo `clientName` ("ANDROID") y no se distinguirían por texto.
  @visibleForTesting
  static List<List<YoutubeApiClient>> get clientFallbacksForTesting =>
      _clientFallbacks.map((clients) => List<YoutubeApiClient>.of(clients)).toList();

  // --- SHARED CIRCUIT BREAKER ---
  // With up to 3 downloads running concurrently (DownloadProvider._maxConcurrentDownloads),
  // each with its own retry loop, independent per-worker backoff meant every worker retried
  // at roughly the same time after YouTube soft-blocked the session, re-triggering the block
  // (a retry storm). This state is static so it's shared across every YoutubeService instance
  // and call path — the same pattern already used by _metadataCache — so all workers pause
  // together instead of hammering YouTube in lockstep.
  static DateTime? _blockedUntil;
  static int _consecutiveBlocks = 0;
  static final Random _jitterRandom = Random();

  /// Whether the shared circuit breaker is active. Wired to DownloadProvider's
  /// "cooldown" setting so users can opt out if they want maximum throughput.
  static bool circuitBreakerEnabled = true;

  /// Limpia el estado del circuit breaker. Para tests: al ser `static`, un test
  /// que provoque un bloqueo deja a los siguientes esperando cooldowns de hasta
  /// 20 min heredados, lo que los hace fallar por timeout por un motivo que no
  /// es el que están probando.
  static void resetCircuitBreaker() {
    _blockedUntil = null;
    _consecutiveBlocks = 0;
  }

  /// Invoca `_recordBlock` desde un test sin tener que fabricar un error de red
  /// real — `_recordBlock` es privado a este archivo, así que un test en otro
  /// archivo no puede llamarlo directamente aunque instancie `YoutubeService`.
  @visibleForTesting
  void recordBlockForTesting() => _recordBlock();

  /// Cuánto falta para que se levante el cooldown activo, o `null` si no hay
  /// ninguno (o ya venció). Para verificar en un test la duración exacta que
  /// calculó `_recordBlock` sin esperarla en tiempo real.
  @visibleForTesting
  static Duration? get blockedRemainingForTesting {
    final until = _blockedUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    return remaining.isNegative ? null : remaining;
  }

  /// Simula que el cooldown activo ya venció, sin tocar `_consecutiveBlocks`.
  /// `_recordBlock` no escala mientras haya un cooldown vigente (a propósito,
  /// para que varios workers concurrentes no atropellen la escalada) — eso
  /// hace que llamar `recordBlockForTesting()` en bucle, sin más, sólo escale
  /// una vez. Esto deja probar la secuencia completa (20, 40, 80, ...) como si
  /// cada bloqueo llegara después de que el anterior ya se enfrió, que es lo
  /// que pasa en producción porque el llamador espera el cooldown completo
  /// antes de volver a intentar.
  @visibleForTesting
  static void clearActiveCooldownForTesting() {
    _blockedUntil = null;
  }

  /// Hook de test para `_getManifestWithFallback`: sustituye la llamada real a
  /// `streamsClient.getManifest` por un fake, para poder probar el orden de la
  /// cascada y el avance de `startIndex`/`clientIndex` sin pegarle a la red.
  @visibleForTesting
  Future<StreamManifest> Function(VideoId videoId, List<YoutubeApiClient> clients)?
      manifestAttemptOverrideForTesting;

  /// Envoltorio público de `_getManifestWithFallback` para tests: el método
  /// real es privado a este archivo y un test en otro archivo no puede
  /// llamarlo directamente aunque instancie `YoutubeService`.
  @visibleForTesting
  Future<({StreamManifest manifest, int clientIndex})> getManifestWithFallbackForTesting(
    YoutubeExplode yt,
    VideoId videoId, {
    bool Function()? isCancelled,
    int startIndex = 0,
  }) =>
      _getManifestWithFallback(
        yt,
        videoId,
        isCancelled: isCancelled,
        startIndex: startIndex,
      );

  /// Cuánto se le permite esperar a una llamada INTERACTIVA (una que tiene una
  /// pantalla bloqueada detrás) antes de rendirse con un error explicativo.
  ///
  /// El cooldown compartido existe para que una tanda de descargas en segundo
  /// plano no realimente el bloqueo de YouTube; ahí esperar los hasta 20 min
  /// completos es lo correcto (ver docs/investigacion_muro_antibot.md: es la
  /// ventana real de recuperación medida). Pero los paths de preview
  /// ("Analizar enlace", búsqueda) dejan la UI deshabilitada mientras esperan,
  /// así que heredar ese mismo cooldown convertiría un breaker en su tramo más
  /// alto en una pantalla muerta durante minutos, sin texto y sin forma de
  /// salir — indistinguible de un cuelgue. Para una petición suelta que un
  /// humano está esperando, es mejor fallar rápido y decir cuánto falta.
  static const Duration _interactiveCooldownCap = Duration(seconds: 8);

  /// Waits out any active global cooldown before a caller issues a new request.
  ///
  /// [isCancelled], when provided, is polled every 300ms so a cancelled
  /// download doesn't keep sleeping for the full remaining cooldown (up to
  /// 20 min) — see `_cancellableDelay` for why this matters.
  ///
  /// [maxWait] hace que la llamada falle en vez de esperar cuando lo que queda de
  /// cooldown lo excede — ver `_interactiveCooldownCap`. Se lanza en lugar de
  /// esperar, así que los llamadores lo invocan FUERA de su `try`/bucle de
  /// reintentos para que propague directamente en vez de convertirse en otro
  /// reintento.
  Future<void> _respectGlobalCooldown(
    String context, {
    bool Function()? isCancelled,
    Duration? maxWait,
  }) async {
    if (!circuitBreakerEnabled) return;
    final until = _blockedUntil;
    if (until == null) return;
    final remaining = until.difference(DateTime.now());
    if (remaining <= Duration.zero) return;
    if (maxWait != null && remaining > maxWait) {
      print('[YouTubeService] $context: cooldown de ${remaining.inSeconds}s excede el techo interactivo, fallando rápido');
      throw Exception(
        'YouTube está limitando las peticiones ahora mismo. '
        'Inténtalo de nuevo en ${remaining.inSeconds}s.',
      );
    }
    print('[YouTubeService] $context: waiting out shared cooldown (${remaining.inSeconds}s remaining)');
    await _cancellableDelay(remaining, isCancelled);
  }

  /// Sleeps for [duration], polling [isCancelled] every 300ms and returning
  /// early the moment it turns true, instead of a single uninterruptible
  /// `Future.delayed`.
  ///
  /// Without this, cancelling a download (or the user resubmitting the same
  /// link right after cancelling) didn't actually stop a worker that was
  /// mid-sleep in the shared circuit-breaker cooldown (up to 20 min) or in a
  /// retry backoff (up to 20s) — it kept sleeping for the full remaining
  /// duration before ever checking cancellation again. Meanwhile that worker
  /// still held its videoId in `DownloadProvider._activeVideoIds`, so a
  /// resubmission of the exact same video would sit blocked behind that
  /// stale lock for however long was left on the old worker's sleep,
  /// appearing "stuck" even though the download had been cancelled.
  Future<void> _cancellableDelay(Duration duration, bool Function()? isCancelled) async {
    if (isCancelled == null) {
      await Future.delayed(duration);
      return;
    }
    const step = Duration(milliseconds: 300);
    var remaining = duration;
    while (remaining > Duration.zero) {
      if (isCancelled()) return;
      final sleepFor = remaining < step ? remaining : step;
      await Future.delayed(sleepFor);
      remaining -= sleepFor;
    }
  }

  /// Registers a hard-block signal (403/401/VideoUnavailableException — YouTube
  /// is actively blocking this session/IP) as opposed to a one-off transient
  /// hiccup. Escalates the cooldown with consecutive blocks so a sustained
  /// block backs off further instead of retrying at a fixed interval forever.
  ///
  /// Skips escalating if we're already inside an active cooldown window: with up
  /// to 3 concurrent download workers, several of them can observe the same
  /// underlying block within the same couple of seconds, and without this guard
  /// each one bumped the shared counter independently, jumping straight to the
  /// longest cooldown tier on the very first real incident instead of escalating
  /// gradually across genuinely separate incidents.
  void _recordBlock() {
    if (!circuitBreakerEnabled) return;
    if (_blockedUntil != null && _blockedUntil!.isAfter(DateTime.now())) return;
    _consecutiveBlocks = (_consecutiveBlocks + 1).clamp(0, 7);
    // 20, 40, 80, 160, 320, 640, 1200 (el último tramo lo recorta el clamp).
    //
    // El techo era 180s (3 min): medido en la sesión de investigación del
    // 2026-07-28 (ver docs/investigacion_muro_antibot.md) que la ventana real
    // de recuperación de una IP bloqueada es de 20-40 min, no minutos. Con el
    // techo viejo el breaker se abría de nuevo mucho antes de que YouTube
    // hubiera dejado de bloquear, y cada intento prematuro contaba como un
    // bloqueo más — alargando la sesión bloqueada en vez de dejarla enfriar.
    final baseSeconds = 20 * (1 << (_consecutiveBlocks - 1));
    final cappedSeconds = baseSeconds.clamp(20, 1200);
    _blockedUntil = DateTime.now().add(Duration(seconds: cappedSeconds));
    print('[YouTubeService] Hard block detected (consecutive: $_consecutiveBlocks) — '
        'all workers will pause for ${cappedSeconds}s');
  }

  void _recordSuccess() {
    _consecutiveBlocks = 0;
    _blockedUntil = null;
  }

  /// True for the errors that indicate YouTube is blocking this session/IP at
  /// large (as opposed to a generic transient network error) — used to decide
  /// whether to trip the *shared* circuit breaker that pauses every concurrent
  /// worker.
  ///
  /// `VideoUnavailableException` IS included here — deliberately, and only
  /// after confirming this with real accounts where the reported "unavailable"
  /// videos were 100% playable normally. `youtube_explode_dart` 3.1.0 (the
  /// version this project pins) determines availability with
  /// `WatchPage.isVideoAvailable`, which just checks for the presence of a
  /// `<meta property="og:url">` tag in the raw watch-page HTML it scraped —
  /// see the vendored source at
  /// `youtube_explode_dart-3.1.0/lib/src/reverse_engineering/pages/watch_page.dart:54`.
  /// If YouTube serves anything else for that request — a bot-check/consent
  /// page, a rate-limit response, or just a differently-shaped page under
  /// load — that tag is missing and the library concludes the video doesn't
  /// exist, even though it does. With 3 concurrent workers scraping watch
  /// pages at once, that's exactly the kind of thing that trips. So in
  /// practice this exception is far more often a mislabeled session-wide
  /// block than a real deletion, and needs the same shared cooldown as
  /// 403/401 so every worker backs off together instead of each hammering
  /// the same (still-blocked) watch page again immediately.
  ///
  /// The earlier version of this method excluded `VideoUnavailableException`
  /// on the assumption it meant one specific video was permanently gone — the
  /// resulting fix (this comment) was a regression: with that exclusion, one
  /// falsely-flagged video could still spin through its own retries without
  /// ever pausing anything, and once several concurrent workers hit the same
  /// real block, none of them backed off coherently. The dedicated guard in
  /// `_recordBlock` (skip escalating while already inside an active cooldown)
  /// is what actually fixes "3 workers pile onto the same incident and jump
  /// straight to the longest tier" — reinstating this classification does not
  /// bring that bug back.
  /// Marca los errores HTTP que vienen de pedir BYTES a googlevideo.com, para
  /// poder distinguirlos de los que vienen de la API de InnerTube.
  static const String streamHttpErrorMarker = 'al descargar el stream';

  bool _isHardBlockError(Object e) {
    final errorStr = e.toString().toLowerCase();

    // Un 403 al pedir los bytes NO es un bloqueo de sesión, y tratarlo como tal
    // sale carísimo. Al no distinguirlo, el 403 de esta clase disparaba el
    // cooldown compartido y lo escalaba 20s->40s->80s->160s a lo largo de los
    // 5 intentos: ~15 minutos atascado en la primera canción, esperando a que
    // se despeje un bloqueo que no existía, para volver a fallar igual porque
    // la causa era determinista.
    //
    // Esa causa determinista es el cliente que resolvió el manifest, no la URL
    // en sí (ver `_streamUserAgent` y Test A/B en
    // docs/investigacion_muro_antibot.md, 2026-07-29) — "pedir un manifest
    // nuevo" con el mismo cliente vuelve a dar la misma URL condenada. El
    // remedio real es escalar al siguiente cliente de `_clientFallbacks`, que
    // es lo que hace `downloadVideoWithAudio` con `manifestStartIndex` al ver
    // este marcador — no simplemente reintentar.
    if (errorStr.contains(streamHttpErrorMarker)) return false;

    // Mismo motivo que la exclusión de arriba, pero para el corte a mitad de
    // descarga: no se sabe todavía si es cliente-condenado o expiración real
    // de URL (ver `MidDownloadCutException`), así que tratarlo como bloqueo de
    // sesión sería tan presuntuoso como lo era antes para el corte al inicio.
    // Se distingue por tipo, no por subcadena, porque el mensaje SÍ puede
    // contener literalmente "403" (parte del diagnóstico, no un marcador) y
    // eso pisaría el match de `errorStr.contains('403')` de más abajo.
    if (e is MidDownloadCutException) return false;

    return errorStr.contains('videounavailableexception') ||
        // VideoUnplayableException es la forma que toma el bloqueo en el paso del
        // MANIFEST, y faltaba aquí. Medido con test/download_smoke_test.dart y
        // tool/client_sweep_probe.dart: una vez que el priming por InnerTube de
        // YTMusicService arregló el paso de metadata, los fallos se movieron
        // enteros a `streamsClient.getManifest`, que lanza
        //   VideoUnplayableException: ... Reason: Sign in to confirm you're not a bot
        // Sin esta línea el breaker NUNCA se activaba para ese caso: el error sí
        // se clasificaba como reintentable, pero por accidente —
        // `_isRetryableError` hace match con 'stream' por el "Streams are not
        // available for this video." del mensaje— así que la descarga quemaba sus
        // 5 intentos con backoffs cortos sin activar nunca el cooldown
        // compartido, manteniendo la sesión bloqueada y haciendo fallar todas las
        // canciones siguientes.
        errorStr.contains('videounplayableexception') ||
        // El marcador inequívoco del muro, independiente del nombre de la
        // excepción que lo envuelva.
        errorStr.contains("confirm you're not a bot") ||
        errorStr.contains('confirm you’re not a bot') ||
        errorStr.contains('403') ||
        errorStr.contains('401') ||
        errorStr.contains('forbidden') ||
        errorStr.contains('unauthorized');
  }

  /// Techo de tiempo para cada petición de red hecha a través de
  /// youtube_explode_dart.
  ///
  /// Hace falta porque la librería NO tiene ninguno: `YoutubeHttpClient` no
  /// define un solo timeout, así que `videos.get()` y `streamsClient
  /// .getManifest()` esperan indefinidamente si el socket se queda colgado —
  /// algo habitual en datos móviles, o cuando YouTube acepta la conexión pero
  /// no responde. `getManifest` es el peor caso: además del POST a InnerTube,
  /// `_parseStreamInfo` dispara un HEAD `getContentLength` POR CADA stream
  /// (6-20 por video), todos igual de destimeoutados, y encima el `retry()`
  /// interno de la librería reintenta hasta 5 veces.
  ///
  /// Ese cuelgue es invisible: no lanza, así que no se registra nada en
  /// download_errors.log y la UI se queda clavada en "Preparando enlace" con el
  /// título ya visible. Lo único que acababa cortando era el
  /// `.timeout(attemptBudget)` de 10 minutos de `_processQueueItem`, dos veces.
  /// Con esto, un socket muerto se convierte en un TimeoutException rápido —
  /// que `_isRetryableError` ya clasifica como reintentable y que sí queda
  /// registrado.
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// El manifest necesita más margen que una petición suelta: la librería hace
  /// un HEAD por stream antes de devolverlo.
  static const Duration _manifestTimeout = Duration(seconds: 45);

  Future<T> _withTimeout<T>(Future<T> future, String what, Duration limit) {
    return future.timeout(
      limit,
      onTimeout: () => throw TimeoutException(
        '$what no respondió en ${limit.inSeconds}s',
      ),
    );
  }

  /// The message thrown when `isCancelled()` goes true mid-download. Centralized
  /// so `isCancellationError` can recognize it instead of every layer matching a
  /// loose string.
  static const String cancelledMessage = 'Descarga cancelada por el usuario';

  /// True when an error is just "the user (or a new session) cancelled this",
  /// not an actual download failure.
  ///
  /// This has to be distinguishable because cancellation used to be laundered
  /// into a genuine failure: it isn't matched by `_isRetryableError`, so the
  /// retry loop wrapped it as `'Error descargando el audio: … Intentos
  /// realizados: N'`, `DownloadProvider` then wrote it to `download_errors.log`
  /// and surfaced it as "Error en descarga después de N intentos". The download
  /// error log ended up full of cancellations, which hid the real errors from
  /// the earlier attempts behind them.
  static bool isCancellationError(Object e) =>
      e.toString().contains(cancelledMessage);

  /// Mensaje que ve el usuario cuando una descarga se aborta por el muro anti-bot.
  static const String botWallMessage =
      'YouTube está pidiendo verificación anti-bot desde esta conexión. '
      'Espera unos minutos antes de volver a intentarlo.';

  /// El marcador inequívoco del muro, independiente del nombre de la excepción
  /// que lo envuelva: llega como `VideoUnplayableException` desde el manifest y
  /// como `VideoUnavailableException` desde el scrape de /watch.
  ///
  /// Se hace match SÓLO contra el texto literal, nunca contra los nombres de las
  /// excepciones: `VideoUnavailableException` también significa "este vídeo se
  /// borró de verdad", y abortar la cascada por eso confundiría un vídeo muerto
  /// con un bloqueo de IP. YouTube manda el apóstrofo tipográfico (’), no el
  /// ASCII, así que hay que cubrir los dos.
  static bool isBotWallError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains("confirm you're not a bot") ||
        s.contains('confirm you’re not a bot');
  }

  /// Adds up to 30% random jitter to a backoff delay so concurrent workers that
  /// failed at nearly the same time don't retry in lockstep.
  int _withJitter(int baseMs) {
    final spread = (baseMs * 0.3).round();
    return spread > 0 ? baseMs + _jitterRandom.nextInt(spread) : baseMs;
  }

  /// Fetches video metadata for a single attempt. Retrying used to happen here too
  /// (up to 3 times), stacked on top of the outer caller's own retry loop — that
  /// tripled the requests fired per failure and was a major contributor to the
  /// retry-storm bug. Now this makes exactly one attempt; retrying happens only at
  /// the outer caller (getVideoInfo / downloadVideoWithAudio), which is also where
  /// the shared circuit breaker is respected.
  Future<Video> _getVideoWithFallback(YoutubeExplode yt, VideoId videoId, {bool Function()? isCancelled}) async {
    await _respectGlobalCooldown('_getVideoWithFallback', isCancelled: isCancelled);
    return await _withTimeout(
      yt.videos.get(videoId),
      'La consulta de metadata',
      _requestTimeout,
    );
  }


  /// Preview for the UI — metadata only, no manifest (avoids burning stream URLs).
  /// Implements automatic retry with backoff for VideoUnavailableException and HTTP 403 errors.
  /// Also tries different client configurations to evade YouTube blocking.
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    final convertedUrl = _convertYouTubeMusicUrl(url);
    final videoId = VideoId(convertedUrl);
    
    Object? lastError;
    const maxRetries = 4; // Total 5 attempts (1 initial + 4 retries) for better reliability
    
    // Try different configurations to evade blocking
    final configs = [
      () => YoutubeExplode(), // Default
      () => YoutubeExplode(), // Fresh instance
      () => YoutubeExplode(), // Another fresh instance
      () => YoutubeExplode(), // Another fresh instance
      () => YoutubeExplode(), // Another fresh instance
    ];
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      // Techo interactivo: hoy este método sólo se llama desde "Analizar enlace"
      // (el path de descarga usa `downloadVideoWithAudio`), así que siempre hay
      // una pantalla esperando. Si algún día se llama desde un batch, esto tiene
      // que volverse un parámetro como en `getPlaylistVideoIds`.
      await _respectGlobalCooldown('getVideoInfo', maxWait: _interactiveCooldownCap);
      final yt = configs[attempt.clamp(0, configs.length - 1)]();
      try {
        final video = await _getVideoWithFallback(yt, videoId);
        final parsed = _parseTitleAndArtist(video.title, video.author);
        final thumbnailUrl = _resolveThumbnailUrl(video, videoId);

        _metadataCache[videoId.value] = _CachedVideoMetadata(
          title: parsed.title,
          artist: parsed.artist,
          duration: video.duration ?? Duration.zero,
          thumbnailUrl: thumbnailUrl,
          cachedAt: DateTime.now(),
        );

        _recordSuccess();
        return {
          'videoId': videoId.value,
          'title': parsed.title,
          'artist': parsed.artist,
          'duration': video.duration ?? Duration.zero,
          'thumbnailUrl': thumbnailUrl,
        };
      } catch (e) {
        lastError = e;

        if (_isHardBlockError(e)) _recordBlock();

        // Check if this is a retryable error
        final isRetryable = _isRetryableError(e);

        if (!isRetryable || attempt >= maxRetries) {
          // Not retryable or max retries reached
          // Include detailed error for debugging
          final errorDetails = 'Error analizando el video: ${e.toString()}\n\nDetalles técnicos:\n${e.runtimeType}\n\nIntentos realizados: ${attempt + 1}';
          throw Exception(errorDetails);
        }

        // Wait with exponential backoff (+ jitter so concurrent workers desync): 3s, 5s, 8s, 12s
        // YouTube needs time to unblock the request
        final delays = [3000, 5000, 8000, 12000];
        final delayMs = _withJitter(delays[attempt.clamp(0, delays.length - 1)]);
        print('[YouTubeService] Retry ${attempt + 1}/${maxRetries} after ${delayMs}ms delay');
        await Future.delayed(Duration(milliseconds: delayMs));
      } finally {
        yt.close();
      }
    }
    
    final errorDetails = 'Error analizando el video: ${lastError.toString()}\n\nDetalles técnicos:\n${lastError.runtimeType}\n\nIntentos realizados: ${maxRetries + 1}';
    throw Exception(errorDetails);
  }

  /// Checks if an error is retryable (VideoUnavailableException or HTTP 403)
  bool _isRetryableError(Object e) {
    final errorStr = e.toString().toLowerCase();
    
    print('[YouTubeService] Checking if error is retryable: $errorStr');
    
    // Check for VideoUnavailableException
    if (errorStr.contains('videounavailableexception')) {
      print('[YouTubeService] -> VideoUnavailableException detected, will retry');
      return true;
    }
    
    // Check for HTTP 403 / 401 errors (stream URL expired or auth failed)
    if (errorStr.contains('403') || errorStr.contains('401') ||
        errorStr.contains('forbidden') || errorStr.contains('unauthorized')) {
      print('[YouTubeService] -> HTTP 403/401 detected, will retry');
      return true;
    }
    
    // Check for YoutubeExplodeException (any, not just 403 — often means invalid response)
    if (errorStr.contains('youtubeexplodeexception')) {
      print('[YouTubeService] -> YoutubeExplodeException detected, will retry');
      return true;
    }

    // youtube_explode_dart 3.1.0's yt.search.search() has a reproducible library
    // bug: NoSuchMethodError ("... has no instance method 'getT'") parsing
    // videoRenderer.viewCountText when YouTube uses the "runs" shape instead of
    // "simpleText" (search_page.dart:181). It's intermittent per-video (~2/3 of
    // queries in a manual repro), not a permanent break, so retrying with a
    // fresh manifest/search call has a real chance of landing on a video whose
    // shape parses fine. See docs/investigacion_muro_antibot.md.
    if (errorStr.contains('nosuchmethoderror')) {
      print('[YouTubeService] -> NoSuchMethodError (bug conocido de search()) detected, will retry');
      return true;
    }

    // Check for chunk download failures (expired stream URL symptoms)
    if (errorStr.contains('chunk') || errorStr.contains('incompleto') ||
        errorStr.contains('incomplete') || errorStr.contains('stream')) {
      print('[YouTubeService] -> Chunk/stream error detected, will retry');
      return true;
    }
    
    // Check for HTTP errors in general (5xx server errors)
    if (errorStr.contains('http 5') || errorStr.contains('500') || 
        errorStr.contains('502') || errorStr.contains('503') || 
        errorStr.contains('504')) {
      print('[YouTubeService] -> HTTP 5xx error detected, will retry');
      return true;
    }
    
    // Check for transient network errors
    if (errorStr.contains('network') || errorStr.contains('connection') || 
        errorStr.contains('timeout') || errorStr.contains('socket')) {
      print('[YouTubeService] -> Network error detected, will retry');
      return true;
    }
    
    // Check for generic unavailable errors
    if (errorStr.contains('unavailable') || errorStr.contains('not available')) {
      print('[YouTubeService] -> Unavailable error detected, will retry');
      return true;
    }
    
    // Check for rate limiting
    if (errorStr.contains('rate limit') || errorStr.contains('429') || 
        errorStr.contains('requestlimitexceeded')) {
      print('[YouTubeService] -> Rate limit detected, will retry');
      return true;
    }

    // Check for OS/file errors that may indicate a transient issue
    if (errorStr.contains('os error') || errorStr.contains('oserror')) {
      print('[YouTubeService] -> OS error detected, will retry');
      return true;
    }
    
    print('[YouTubeService] -> Error not retryable: $errorStr');
    return false;
  }

  /// Downloads audio using a fresh YoutubeExplode session with alternative clients
  /// that bypass the YouTube "n-parameter" throttling.
  /// Implements automatic retry with backoff for download errors.
  Future<Map<String, dynamic>> downloadVideoWithAudio(
    String url, {
    void Function(String title)? onMetadata,
    void Function(double)? onProgress,
    void Function(String phase)? onPhase,
    bool Function()? isCancelled,
  }) async {
    // Convertir enlaces de YouTube Music a YouTube estándar
    final convertedUrl = _convertYouTubeMusicUrl(url);
    final videoId = VideoId(convertedUrl);
    final cached = _metadataCache[videoId.value];

    Object? lastError;
    // Avanza sólo cuando un cliente ya dio 403-en-bytes (ver el catch de más
    // abajo) — nunca vuelve a 0 dentro de la misma llamada, para no repetir un
    // cliente ya descartado en el siguiente intento.
    var manifestStartIndex = 0;
    // 3 intentos (1 inicial + 2 reintentos). Eran 5, y los dos últimos casi nunca
    // aportaban: cuando YouTube sirve el muro lo sirve a TODOS los clientes de la
    // sesión a la vez (medido en tool/client_sweep_probe.dart), así que insistir
    // sólo gastaba presupuesto de IP y alargaba el fallo. Medido en
    // test/download_smoke_test.dart: los 5 intentos llegaban al mismo error a los
    // 147ms, 7.3s, 29.4s, 71.4s y 154.3s.
    const maxRetries = 2;

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      if (isCancelled != null && isCancelled()) {
        throw Exception(cancelledMessage);
      }
      await _respectGlobalCooldown('downloadVideoWithAudio', isCancelled: isCancelled);
      final yt = YoutubeExplode();
      int? usedClientIndex;
      try {
        late final ({String title, String artist}) parsed;
        late final Duration duration;
        late final String thumbnailUrl;

        if (cached != null && cached.isValid) {
          parsed = (title: cached.title, artist: cached.artist);
          duration = cached.duration;
          thumbnailUrl = cached.thumbnailUrl;
          onMetadata?.call(parsed.title);
        } else {
          onPhase?.call('metadata');
          final video = await _getVideoWithFallback(yt, videoId, isCancelled: isCancelled);
          parsed = _parseTitleAndArtist(video.title, video.author);
          duration = video.duration ?? Duration.zero;
          thumbnailUrl = _resolveThumbnailUrl(video, videoId);
          onMetadata?.call(parsed.title);

          _metadataCache[videoId.value] = _CachedVideoMetadata(
            title: parsed.title,
            artist: parsed.artist,
            duration: duration,
            thumbnailUrl: thumbnailUrl,
            cachedAt: DateTime.now(),
          );
        }

        onPhase?.call('manifest');

        // Always fetch a fresh manifest on retries — stream URLs expire quickly.
        final manifestResult = await _getManifestWithFallback(
          yt,
          videoId,
          isCancelled: isCancelled,
          startIndex: manifestStartIndex,
        );
        usedClientIndex = manifestResult.clientIndex;

        final selectedStream = _selectBestAudioStream(manifestResult.manifest);

        onPhase?.call('downloading');

        // Download thumbnail concurrently in the background
        final Future<String> thumbnailDownloadFuture = downloadThumbnail(
          videoId.value,
          thumbnailUrl,
        );

        final localAudioPath = await _downloadViaParallelChunks(
          selectedStream,
          onProgress: onProgress,
          isCancelled: isCancelled,
          manifestClientIndex: usedClientIndex,
        );

        final localThumbnailPath = await thumbnailDownloadFuture;

        _recordSuccess();
        return {
          'videoId': videoId.value,
          'title': parsed.title,
          'artist': parsed.artist,
          'duration': duration,
          'format': selectedStream.container.name,
          'thumbnailUrl': thumbnailUrl,
          'filePath': localAudioPath,
          'artPath': localThumbnailPath,
        };
      } catch (e) {
        lastError = e;

        // A cancellation isn't a download failure — propagate it verbatim so the
        // caller can tell the two apart, before it gets counted as an attempt,
        // trips the circuit breaker, or gets wrapped in an "Error descargando el
        // audio" message that lands in the user's error log.
        if (isCancellationError(e)) rethrow;

        // Corte temprano por muro anti-bot: no quedan reintentos que valga la pena
        // gastar. `_getManifestWithFallback` ya abandonó la cascada de clientes y
        // ya disparó el circuit breaker compartido; insistir aquí sólo alargaría el
        // fallo y añadiría peticiones al presupuesto de IP, que es exactamente lo
        // que mantiene el bloqueo vivo. Se falla rápido y con un mensaje que
        // explica que no es culpa del vídeo.
        if (e is BotWallException) {
          print('[YouTubeService] Muro anti-bot en el intento ${attempt + 1}: '
              'se abandonan los ${maxRetries - attempt} reintentos restantes');
          throw Exception('$botWallMessage\n\nIntentos realizados: ${attempt + 1}\n\n$e');
        }

        // 403-en-bytes (ver `_clientFallbacks` y Test A/B en
        // docs/investigacion_muro_antibot.md, 2026-07-29): no es una URL al azar
        // caducada, es el cliente concreto que resolvió el manifest. Pedir "un
        // manifest nuevo" sin más siempre volvía a elegir el mismo cliente
        // determinista y repetía el mismo 403 — gastando presupuesto de IP sin
        // arreglar nada. Se avanza la cascada al siguiente cliente para el
        // próximo intento en vez de reintentar con el que ya se sabe que falla.
        if (usedClientIndex != null &&
            e.toString().toLowerCase().contains(streamHttpErrorMarker)) {
          manifestStartIndex = usedClientIndex + 1;
          print('[YouTubeService] 403 en bytes con cliente #$usedClientIndex — '
              'el próximo intento escala al cliente #$manifestStartIndex');
        }

        if (_isHardBlockError(e)) _recordBlock();

        // Check if this is a retryable error
        final isRetryable = _isRetryableError(e);

        if (!isRetryable || attempt >= maxRetries) {
          // Not retryable or max retries reached
          if (_isRateLimitError(e)) rethrow;
          print('[YouTubeService] Download failed after ${attempt + 1} attempts: $e');
          throw Exception('Error descargando el audio: ${e.toString()}\n\nIntentos realizados: ${attempt + 1}');
        }

        // Longer exponential backoff (+ jitter so concurrent workers desync): 5s, 10s, 15s, 20s
        // YouTube stream URLs expire and need real time before a new one works.
        final delays = [5000, 10000, 15000, 20000];
        final delayMs = _withJitter(delays[attempt.clamp(0, delays.length - 1)]);
        print('[YouTubeService] Download retry ${attempt + 1}/${maxRetries} after ${delayMs}ms delay: $e');
        await _cancellableDelay(Duration(milliseconds: delayMs), isCancelled);
      } finally {
        yt.close();
      }
    }

    if (lastError != null && _isRateLimitError(lastError)) {
      throw lastError;
    }
    print('[YouTubeService] Download failed after ${maxRetries + 1} attempts');
    throw Exception('Error descargando el audio: ${lastError.toString()}\n\nIntentos realizados: ${maxRetries + 1}');
  }

  /// Fetches the stream manifest trying all client fallbacks.
  ///
  /// Every call passes `requireWatchPage: false`. In youtube_explode_dart 3.1.0
  /// that parameter defaults to `true`, and with it on, `StreamClient._getStream`
  /// does `watchPage = await WatchPage.get(...)` *before* it ever touches the
  /// InnerTube player endpoint — i.e. the stream step scraped the same raw
  /// `/watch` HTML that `videos.get()` does, once per client in the cascade
  /// below. `WatchPage.get` throws `TransientFailureException('Video watch page
  /// is broken.')` whenever the scraped page has no `#player` element, which is
  /// what YouTube's "sign in to confirm you're not a bot" wall looks like.
  ///
  /// Skipping it is safe for the Android clients used here:
  /// `VideoController.getPlayerResponse` treats `watchPage` as optional (it only
  /// supplies the `STS`/visitor-id extras) and stream deciphering in
  /// `_parseStreamInfo` is gated behind `watchPage != null`, because these
  /// clients return unciphered stream URLs — not needing that scrape is the
  /// entire reason they exist.
  ///
  /// CAVEAT, measured: this is an optimization, NOT a proven fix for the
  /// intermittent download failures. A repeated A/B against the video IDs from a
  /// real `download_errors.log` showed `true` and `false` both succeeding 6/6
  /// while YouTube wasn't blocking this host — the only reliable difference was
  /// latency (~335ms vs ~1424ms) and one fewer HTTP request per attempt. It
  /// removes a known-fragile request from the hot path and lowers request
  /// volume, which is worth having, but do not assume it makes the block go
  /// away. The failures were not reproducible from a desktop connection at all.
  /// Cada intento lleva su propio `_manifestTimeout`, y el conjunto está acotado
  /// además por [isCancelled]: antes, con 4 configuraciones probadas en serie y
  /// ninguna con techo de tiempo, un solo socket colgado bloqueaba la descarga
  /// indefinidamente y de forma silenciosa.
  ///
  /// [startIndex] hace que la cascada empiece más adelante que el primer
  /// cliente de `_clientFallbacks`. Existe para el 403-en-bytes: ese fallo pasa
  /// el manifest (no lo detecta esta función) y sólo aparece al pedir los
  /// bytes con el cliente que lo resolvió, así que "pedir un manifest nuevo"
  /// sin más vuelve a elegir el mismo cliente determinista y repite el mismo
  /// 403. El resultado incluye el índice usado para que el llamador pueda
  /// pedir que se lo salte en el siguiente intento.
  Future<({StreamManifest manifest, int clientIndex})> _getManifestWithFallback(
    YoutubeExplode yt,
    VideoId videoId, {
    bool Function()? isCancelled,
    int startIndex = 0,
  }) async {
    Future<StreamManifest> attempt(List<YoutubeApiClient> clients) {
      final override = manifestAttemptOverrideForTesting;
      if (override != null) return override(videoId, clients);
      return _withTimeout(
        yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: clients,
          requireWatchPage: false,
        ),
        'La obtención de streams',
        _manifestTimeout,
      );
    }

    // Se pasa SIEMPRE una lista explícita de clientes. Antes había un primer
    // intento con `attempt(null)`, y ese `null` tenía dos costes ocultos:
    //
    // 1. `StreamClient.getManifest` con `ytClients == null` usa `[androidSdkless]`
    //    y, si no obtiene ningún stream, se REINTENTA solo con
    //    `[YoutubeApiClient.tv]` (stream_client.dart:126-127). Ese cliente declara
    //    userAgent "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version,gzip(gfe)",
    //    mientras que los bytes se piden con `_streamUserAgent` (el UA de la app de
    //    Android). YouTube liga las URLs de stream al cliente que las pidió y valida
    //    que quien pide los bytes sea el mismo, así que un manifest resuelto por
    //    `tv` daba 403 de forma determinista. El comentario de `_streamUserAgent`
    //    daba por hecho que todos los caminos usaban el UA de Android: cierto para
    //    `_clientFallbacks`, falso para este `null`. Confirmado en una corrida del
    //    smoke test, donde el "cliente por defecto" falló con
    //    VideoUnavailableException mientras los explícitos daban
    //    VideoUnplayableException — la firma de haber pasado por `tv`.
    // 2. Duplicaba `androidSdkless`, que ya está en la cascada de abajo: una
    //    petición repetida por intento, puro gasto de presupuesto de IP.
    Object? lastError;
    // Clamp en vez de fallar: si un intento anterior ya agotó la cascada
    // escalando por 403-en-bytes, se reintenta desde el último cliente en vez
    // de quedar sin ninguno que probar.
    final effectiveStart = startIndex.clamp(0, _clientFallbacks.length - 1);
    for (var i = effectiveStart; i < _clientFallbacks.length; i++) {
      final clients = _clientFallbacks[i];
      final names = clients
          .map((c) => c.payload['context']['client']['clientName'])
          .join('+');
      if (isCancelled != null && isCancelled()) {
        throw Exception(cancelledMessage);
      }
      // Log de CADA intento, no sólo de los que fallan — sin esto no hay forma
      // de contar cuántas peticiones de manifest emitió una descarga (medida
      // clave de docs/investigacion_muro_antibot.md: comparar esa cifra contra
      // el baseline de `main` es la métrica principal, más que "cuántas
      // completan").
      print('[YouTubeService] Manifest intento #$i ($names)');
      try {
        return (manifest: await attempt(clients), clientIndex: i);
      } catch (e) {
        lastError = e;
        print('[YouTubeService] Manifest ($names) falló: $e');

        // Corte temprano. El muro anti-bot es de SESIÓN/IP, no de cliente ni de
        // vídeo: `tool/client_sweep_probe.dart` mide que los 11 clientes de
        // InnerTube fallan a la vez en cuanto la sesión está bloqueada. Seguir la
        // cascada es gastar peticiones en algo que ya se sabe que va a fallar, y
        // cada una empeora el bloqueo que estamos intentando esquivar. Se abandona
        // la cascada entera, se dispara el breaker en el acto y se envuelve en un
        // tipo propio para que `downloadVideoWithAudio` lo distinga sin volver a
        // hacer match por subcadena.
        if (isBotWallError(e)) {
          _recordBlock();
          throw BotWallException(e);
        }
      }
    }
    throw lastError ?? Exception('No se pudieron obtener streams de audio.');
  }

  /// Techo de tiempo ENTRE páginas de un stream paginado (la expansión de una
  /// playlist). No acota el total —una playlist de 500 temas legítimamente tarda—
  /// sino el hueco sin recibir nada, que es la firma de un socket muerto.
  static const Duration _playlistPageTimeout = Duration(seconds: 30);

  /// Resuelve todos los video IDs de una playlist.
  ///
  /// [isCancelled] importa porque este método NO es sólo el preview de "Analizar
  /// enlace": `DownloadProvider.downloadPlaylist` lo llama para expandir la lista
  /// antes de encolar nada. Un cuelgue aquí ocurre por tanto *dentro* de una
  /// descarga, pero antes de que exista un item en `download_queue` — así que ni
  /// el `attemptBudget` de `_processQueueItem` ni `cancelAllDownloads()` lo
  /// alcanzaban, y la UI se quedaba en "Analizando lista de reproducción..." de
  /// forma indefinida y silenciosa.
  ///
  /// [interactive] distingue los dos llamadores: `true` para el preview de
  /// "Analizar enlace" (hay una pantalla bloqueada, así que un cooldown largo se
  /// convierte en error rápido — ver `_interactiveCooldownCap`), `false` para
  /// `downloadPlaylist`, que corre en segundo plano y debe esperar el cooldown
  /// completo para no realimentar el bloqueo.
  Future<List<String>> getPlaylistVideoIds(
    String url, {
    bool Function()? isCancelled,
    bool interactive = false,
  }) async {
    try {
      // Convertir enlaces de YouTube Music a YouTube estándar
      final convertedUrl = _convertYouTubeMusicUrl(url);
      final customIds = await _customScrapePlaylist(convertedUrl, isCancelled: isCancelled);
      if (customIds.isNotEmpty) {
        return customIds;
      }
    } catch (e) {
      // Idem: sin esto, cancelar durante el scraper propio sólo lo saltaba y
      // acto seguido arrancaba el intento con youtube_explode_dart.
      if (isCancellationError(e)) rethrow;
      print('Custom playlist scraper failed, falling back to YoutubeExplode: $e');
    }

    Object? lastError;
    const maxRetries = 2; // Total 3 attempts

    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      if (isCancelled != null && isCancelled()) {
        throw Exception(cancelledMessage);
      }
      await _respectGlobalCooldown(
        'getPlaylistVideoIds',
        isCancelled: isCancelled,
        maxWait: interactive ? _interactiveCooldownCap : null,
      );
      final yt = YoutubeExplode();
      try {
        final convertedUrl = _convertYouTubeMusicUrl(url);
        final playlistId = PlaylistId(convertedUrl);
        final List<String> videoIds = [];

        // `.timeout(...)` sobre el stream, no sobre el future completo: la
        // librería pagina internamente (~100 videos por petición) y no expone
        // ningún timeout, así que un socket que muere a mitad de la paginación
        // dejaba este `await for` esperando para siempre — sin lanzar, sin
        // registrar nada. El timeout por evento corta ese caso sin penalizar a
        // las playlists grandes, que sí siguen recibiendo páginas.
        await for (final video
            in yt.playlists.getVideos(playlistId).timeout(_playlistPageTimeout)) {
          if (isCancelled != null && isCancelled()) {
            throw Exception(cancelledMessage);
          }
          if (video.id.value.isNotEmpty) {
            videoIds.add(video.id.value);
          }
        }

        _recordSuccess();
        return videoIds;
      } catch (e) {
        lastError = e;

        if (isCancellationError(e)) rethrow;

        if (_isHardBlockError(e)) _recordBlock();

        // Check if this is a retryable error
        final isRetryable = _isRetryableError(e);

        if (!isRetryable || attempt >= maxRetries) {
          throw Exception(
            'Error cargando la lista de reproducción: ${e.toString()}',
          );
        }

        // Wait 2-3 seconds before retrying (+ jitter)
        final delayMs = _withJitter(2000 + (attempt * 500));
        await _cancellableDelay(Duration(milliseconds: delayMs), isCancelled);
      } finally {
        yt.close();
      }
    }
    
    throw Exception(
      'Error cargando la lista de reproducción: ${lastError.toString()}',
    );
  }

  /// Busca videos en YouTube por query
  Future<List<YouTubeSearchResult>> searchVideos(String query, {int maxResults = 20}) async {
    Object? lastError;
    const maxRetries = 2; // Total 3 attempts
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      // Idem: la búsqueda siempre es interactiva. El path de descarga de Spotify
      // hace su propia búsqueda en `searchAndDownload`, que sí espera el cooldown
      // completo porque corre en segundo plano.
      await _respectGlobalCooldown('searchVideos', maxWait: _interactiveCooldownCap);
      final yt = YoutubeExplode();
      try {
        final results = <YouTubeSearchResult>[];

        final searchResults = await _withTimeout(
          yt.search.search(query),
          'La búsqueda',
          _requestTimeout,
        );

        for (final video in searchResults) {
          if (results.length >= maxResults) break;
          
          final videoId = video.id;
          final parsed = _parseTitleAndArtist(video.title, video.author);
          final thumbnailUrl = _resolveThumbnailUrl(video, videoId);
          final url = 'https://www.youtube.com/watch?v=${videoId.value}';

          results.add(YouTubeSearchResult(
            videoId: videoId.value,
            title: parsed.title,
            artist: parsed.artist,
            duration: video.duration ?? Duration.zero,
            thumbnailUrl: thumbnailUrl,
            url: url,
          ));

          // Cache metadata for future use
          _metadataCache[videoId.value] = _CachedVideoMetadata(
            title: parsed.title,
            artist: parsed.artist,
            duration: video.duration ?? Duration.zero,
            thumbnailUrl: thumbnailUrl,
            cachedAt: DateTime.now(),
          );
        }

        _recordSuccess();
        return results;
      } catch (e) {
        lastError = e;

        if (_isHardBlockError(e)) _recordBlock();

        // Check if this is a retryable error
        final isRetryable = _isRetryableError(e);

        if (!isRetryable || attempt >= maxRetries) {
          throw Exception('Error buscando videos: ${e.toString()}');
        }

        // Wait 2-3 seconds before retrying (+ jitter)
        final delayMs = _withJitter(2000 + (attempt * 500));
        await Future.delayed(Duration(milliseconds: delayMs));
      } finally {
        yt.close();
      }
    }

    throw Exception('Error buscando videos: ${lastError.toString()}');
  }

  /// Scraper propio de playlists — el primer intento de `getPlaylistVideoIds`.
  ///
  /// `client.connectionTimeout` sólo acota el ESTABLECIMIENTO de la conexión, no
  /// la lectura del cuerpo: con la conexión ya abierta, tanto el `.join()` del
  /// HTML inicial como los POST de continuación del bucle de paginación (hasta 50
  /// iteraciones) podían quedarse esperando indefinidamente si YouTube aceptaba
  /// la conexión y luego no respondía. Al ser el primer intento del método, un
  /// cuelgue aquí colgaba la resolución de la playlist entera antes incluso de
  /// llegar al fallback de youtube_explode_dart.
  Future<List<String>> _customScrapePlaylist(String url, {bool Function()? isCancelled}) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final List<String> videoIds = [];
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      final response = await _withTimeout(
        request.close(),
        'La petición de la lista',
        _requestTimeout,
      );
      final html = await _withTimeout(
        response.transform(utf8.decoder).join(),
        'La lectura de la lista',
        _requestTimeout,
      );

      final match = RegExp(r'var ytInitialData\s*=\s*(\{.*?\});').firstMatch(html);
      if (match == null) return [];
      
      final data = jsonDecode(match.group(1)!);
      
      // Extract videos from first page
      try {
        final tabContent = data["contents"]["twoColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"];
        final contents = tabContent["sectionListRenderer"]["contents"][0]["itemSectionRenderer"]["contents"];
        for (final item in contents) {
          final lockup = item["lockupViewModel"];
          if (lockup != null && lockup["contentType"] == "LOCKUP_CONTENT_TYPE_VIDEO") {
            final contentId = lockup["contentId"];
            if (contentId != null && contentId.toString().isNotEmpty) {
              videoIds.add(contentId.toString());
            }
          } else if (item["playlistVideoRenderer"] != null) {
            final videoId = item["playlistVideoRenderer"]["videoId"];
            if (videoId != null && videoId.toString().isNotEmpty) {
              videoIds.add(videoId.toString());
            }
          }
        }
      } catch (e) {
        print('Error parsing initial videos in custom scraper: $e');
      }
      
      // Find API key
      final apiKeyMatch = RegExp(r'"INNERTUBE_API_KEY"\s*:\s*"([^"]+)"').firstMatch(html);
      final apiKey = apiKeyMatch?.group(1) ?? 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
      
      // Extract initial continuation token
      String? token;
      try {
        final tabContent = data["contents"]["twoColumnBrowseResultsRenderer"]["tabs"][0]["tabRenderer"]["content"];
        final sectionContents = tabContent["sectionListRenderer"]["contents"];
        
        if (sectionContents.isNotEmpty && sectionContents[0]["itemSectionRenderer"] != null) {
          final items = sectionContents[0]["itemSectionRenderer"]["contents"];
          if (items.isNotEmpty) {
            final lastItem = items.last;
            if (lastItem["continuationItemRenderer"] != null) {
              token = lastItem["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"];
            } else if (lastItem["continuationItemViewModel"] != null) {
              token = lastItem["continuationItemViewModel"]["continuationCommand"]["token"] ?? 
                      lastItem["continuationItemViewModel"]["continuationCommand"]["innertubeCommand"]["continuationCommand"]["token"];
            }
          }
        }
        
        if (token == null && sectionContents.length > 1) {
          final continuationItem = sectionContents[1]["continuationItemViewModel"];
          if (continuationItem != null) {
            token = continuationItem["continuationCommand"]["token"] ?? 
                    continuationItem["continuationCommand"]["innertubeCommand"]["continuationCommand"]["token"];
          }
        }
      } catch (e) {
        print('Error parsing initial token in custom scraper: $e');
      }
      
      int safetyCounter = 0;
      while (token != null && token.isNotEmpty && safetyCounter < 50) {
        if (isCancelled != null && isCancelled()) {
          throw Exception(cancelledMessage);
        }
        safetyCounter++;
        final postUri = Uri.parse('https://www.youtube.com/youtubei/v1/browse?key=$apiKey');
        final postRequest = await client.postUrl(postUri);
        postRequest.headers.set('Content-Type', 'application/json');
        postRequest.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
        
        final payload = {
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20240101.00.00'
            }
          },
          'continuation': token
        };
        
        postRequest.write(jsonEncode(payload));
        final postResponse = await _withTimeout(
          postRequest.close(),
          'La página $safetyCounter de la lista',
          _requestTimeout,
        );
        final postHtml = await _withTimeout(
          postResponse.transform(utf8.decoder).join(),
          'La lectura de la página $safetyCounter',
          _requestTimeout,
        );
        final responseData = jsonDecode(postHtml);
        
        String? nextToken;
        try {
          final actions = responseData["onResponseReceivedActions"];
          if (actions != null && actions.isNotEmpty) {
            final appendAction = actions[0]["appendContinuationItemsAction"];
            if (appendAction != null) {
              final continuationItems = appendAction["continuationItems"];
              if (continuationItems != null) {
                for (final item in continuationItems) {
                  if (item is Map) {
                    if (item["lockupViewModel"] != null) {
                      final contentId = item["lockupViewModel"]["contentId"];
                      if (contentId != null && contentId.toString().isNotEmpty) {
                        videoIds.add(contentId.toString());
                      }
                    } else if (item["playlistVideoRenderer"] != null) {
                      final videoId = item["playlistVideoRenderer"]["videoId"];
                      if (videoId != null && videoId.toString().isNotEmpty) {
                        videoIds.add(videoId.toString());
                      }
                    } else if (item["continuationItemRenderer"] != null) {
                      nextToken = item["continuationItemRenderer"]["continuationEndpoint"]["continuationCommand"]["token"];
                    } else if (item["continuationItemViewModel"] != null) {
                      nextToken = item["continuationItemViewModel"]["continuationCommand"]["token"] ??
                                  item["continuationItemViewModel"]["continuationCommand"]["innertubeCommand"]["continuationCommand"]["token"];
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          print('Error parsing page $safetyCounter in custom scraper: $e');
        }
        
        token = nextToken;
      }
    } catch (e) {
      // Una cancelación tiene que propagarse: este catch devuelve `videoIds`
      // tal cual, así que tragársela haría que una lista a medio expandir
      // pareciera una expansión completa y correcta, y `getPlaylistVideoIds`
      // encolaría sólo los temas resueltos hasta el momento de cancelar.
      if (isCancellationError(e)) rethrow;
      print('Custom scraper failed: $e');
    } finally {
      client.close();
    }
    return videoIds;
  }

  Future<String> downloadAudio(
    String videoId,
    String unusedStreamUrl,
    String format, {
    void Function(double)? onProgress,
  }) async {
    final result = await downloadVideoWithAudio(
      'https://www.youtube.com/watch?v=$videoId',
      onProgress: onProgress,
    );
    return result['filePath'] as String;
  }

  AudioOnlyStreamInfo _selectBestAudioStream(StreamManifest manifest) {
    final directAudio = manifest.audioOnly
        .whereType<AudioOnlyStreamInfo>()
        .where((s) => s.fragments.isEmpty)
        .toList();

    if (directAudio.isNotEmpty) {
      // Prioridad: Opus 160kbps > Opus 128kbps > AAC 128kbps > AAC 96kbps > cualquiera
      final opusHigh = directAudio
          .where((s) => s.container.name == 'webm')
          .where((s) => s.bitrate.kiloBitsPerSecond >= 150)
          .toList();
      if (opusHigh.isNotEmpty) return opusHigh.withHighestBitrate();

      final opusMedium = directAudio
          .where((s) => s.container.name == 'webm')
          .where((s) => s.bitrate.kiloBitsPerSecond >= 120)
          .toList();
      if (opusMedium.isNotEmpty) return opusMedium.withHighestBitrate();

      final m4a = directAudio
          .where((s) => s.container.name == 'm4a' || s.container.name == 'mp4')
          .toList();
      if (m4a.isNotEmpty) {
        // Preferir tag 140 (128kbps AAC) si está disponible
        final reliable = m4a.where((s) => s.tag == 140).firstOrNull;
        if (reliable != null) return reliable;
        return m4a.withHighestBitrate();
      }
      return directAudio.withHighestBitrate();
    }

    final anyAudio = manifest.audioOnly.whereType<AudioOnlyStreamInfo>().toList();
    if (anyAudio.isNotEmpty) return anyAudio.withHighestBitrate();

    throw Exception('No hay streams de audio disponibles para este video.');
  }

  /// Decide qué hacer ante un status ≠ 200/206 en el bucle de chunks de
  /// `_downloadSequential`. Con `receivedSoFar == 0` (chunk 0) no lanza — deja
  /// que el llamador haga `break` y caiga al fallback sin Range, que ya cubre
  /// ese caso. Con `receivedSoFar > 0` (corte a mitad de la descarga) lanza
  /// `MidDownloadCutException` con los datos de diagnóstico: sin ellos, el
  /// primer caso real de esto sería indiagnosticable — no sabríamos si fue
  /// cliente-condenado o expiración real de URL (ver el docstring de la
  /// excepción).
  void _checkMidChunkStatus({
    required int statusCode,
    required int receivedSoFar,
    required int chunkIndex,
    required int totalBytes,
    int? manifestClientIndex,
  }) {
    if (receivedSoFar == 0) return;

    final names = manifestClientIndex != null &&
            manifestClientIndex >= 0 &&
            manifestClientIndex < _clientFallbacks.length
        ? _clientFallbacks[manifestClientIndex]
            .map((c) => c.payload['context']['client']['clientName'])
            .join('+')
        : null;
    print('[YouTubeService] Corte a mitad de descarga: HTTP $statusCode en '
        'el chunk $chunkIndex ($receivedSoFar/$totalBytes bytes), cliente de '
        'manifest #$manifestClientIndex ($names)');
    throw MidDownloadCutException(
      statusCode: statusCode,
      chunkIndex: chunkIndex,
      bytesReceived: receivedSoFar,
      totalBytes: totalBytes,
      manifestClientIndex: manifestClientIndex,
      manifestClientNames: names,
    );
  }

  /// Envoltorio público de `_checkMidChunkStatus` para tests: el método real
  /// es privado a este archivo.
  @visibleForTesting
  void checkMidChunkStatusForTesting({
    required int statusCode,
    required int receivedSoFar,
    required int chunkIndex,
    required int totalBytes,
    int? manifestClientIndex,
  }) =>
      _checkMidChunkStatus(
        statusCode: statusCode,
        receivedSoFar: receivedSoFar,
        chunkIndex: chunkIndex,
        totalBytes: totalBytes,
        manifestClientIndex: manifestClientIndex,
      );


  /// Downloads audio using parallel HTTP Range requests (4 concurrent workers).
  /// Chunks are downloaded concurrently into memory and then written sequentially
  /// to avoid RandomAccessFile race conditions that corrupt the output file.
  /// Downloads audio using a simple sequential HTTP connection.
  /// This is extremely reliable, avoids CPU/network race conditions, and bypasses
  /// YouTube limits regarding concurrent range requests.
  Future<String> _downloadViaParallelChunks(
    AudioOnlyStreamInfo streamInfo, {
    void Function(double)? onProgress,
    bool Function()? isCancelled,
    int? manifestClientIndex,
  }) async {
    final videoId = streamInfo.videoId.value;
    final docDir = await getApplicationDocumentsDirectory();
    final musicDir = Directory('${docDir.path}/music');

    if (!await musicDir.exists()) {
      await musicDir.create(recursive: true);
    }

    final ext = streamInfo.container.name;
    final finalExt = (ext == 'mp4' || ext == 'm4a') ? 'm4a' : 'webm';
    final filePath = '${musicDir.path}/$videoId.$finalExt';
    final file = File(filePath);
    final totalBytes = streamInfo.size.totalBytes;

    // Check if already fully downloaded
    if (file.existsSync()) {
      final existing = file.lengthSync();
      if (totalBytes > 0 && existing >= totalBytes) {
        onProgress?.call(1.0);
        return filePath;
      }
      try { file.deleteSync(); } catch (_) {}
    }

    return _downloadSequential(
      streamInfo,
      file,
      filePath,
      onProgress,
      isCancelled,
      manifestClientIndex,
    );
  }

  Future<String> _downloadSequential(
    AudioOnlyStreamInfo streamInfo,
    File file,
    String filePath,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
    int? manifestClientIndex,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    final sink = file.openWrite();
    var received = 0;
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final totalBytes = streamInfo.size.totalBytes;
    final url = streamInfo.url;

    try {
      if (totalBytes > 0) {
        // Intentar descarga por fragmentos de 5MB
        const chunkSize = 5 * 1024 * 1024;
        var chunkIndex = 0;
        while (received < totalBytes) {
          if (isCancelled != null && isCancelled()) {
            throw Exception(cancelledMessage);
          }

          // Progreso de esta iteración: el `while` avanza sólo si `received`
          // crece, y nada garantizaba que creciera. Un 206 con cuerpo vacío hace
          // que el `await for` de abajo termine sin emitir un solo chunk, dejando
          // `received` intacto y al bucle repitiendo EXACTAMENTE el mismo Range
          // para siempre. Ningún timeout lo detecta, porque cada petición
          // individual responde rápido y correctamente: la descarga se queda
          // clavada en el mismo porcentaje quemando red y batería de forma
          // indefinida. Con esto se corta y se deja reintentar al bucle externo
          // ("chunk" hace que `_isRetryableError` lo clasifique como reintentable).
          final receivedBeforeChunk = received;

          final end = (received + chunkSize - 1) < totalBytes
              ? (received + chunkSize - 1)
              : totalBytes - 1;

          final request = await client.getUrl(url);
          _addHeaders(request);
          request.headers.add('Range', 'bytes=$received-$end');
          
          final response = await request.close().timeout(const Duration(seconds: 20));

          if (response.statusCode != 200 && response.statusCode != 206) {
            _checkMidChunkStatus(
              statusCode: response.statusCode,
              receivedSoFar: received,
              chunkIndex: chunkIndex,
              totalBytes: totalBytes,
              manifestClientIndex: manifestClientIndex,
            );
            // Sólo llega acá si `receivedSoFar == 0` (chunk 0) — el método de
            // arriba ya lanzó para el caso de corte a mitad. Se sale del loop
            // chunked para caer en la descarga directa sin Range de más abajo,
            // que ya cubre este caso (y, si también falla, lanza con
            // `streamHttpErrorMarker`).
            break;
          }
          chunkIndex++;

          await for (final chunk in response.timeout(
            const Duration(seconds: 60),
            onTimeout: (eventSink) => eventSink.addError(
              TimeoutException('Sin datos del servidor durante 60s'),
            ),
          )) {
            if (isCancelled != null && isCancelled()) {
              throw Exception(cancelledMessage);
            }
            sink.add(chunk);
            received += chunk.length;

            if (onProgress != null && totalBytes > 0) {
              final now = DateTime.now();
              final percent = received / totalBytes;
              if (percent >= 1.0 ||
                  now.difference(lastUiUpdate).inMilliseconds >= 200) {
                lastUiUpdate = now;
                onProgress(percent.clamp(0.0, 0.99));
              }
            }
          }

          if (received == receivedBeforeChunk) {
            throw Exception(
              'El servidor devolvió un chunk vacío en el byte $received '
              'de $totalBytes; abortando para no repetir la misma petición.',
            );
          }
        }
      }

      // Si no se descargó nada por el esquema de chunks (totalBytes <= 0 o Range no soportado)
      if (received == 0) {
        final request = await client.getUrl(url);
        _addHeaders(request);
        final response = await request.close().timeout(const Duration(seconds: 20));

        if (response.statusCode != 200 && response.statusCode != 206) {
          throw HttpException(
              'HTTP ${response.statusCode} $streamHttpErrorMarker');
        }

        final expectedTotal = response.contentLength > 0 ? response.contentLength : totalBytes;

        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
          onTimeout: (eventSink) => eventSink.addError(
            TimeoutException('Sin datos del servidor durante 60s'),
          ),
        )) {
          if (isCancelled != null && isCancelled()) {
            throw Exception(cancelledMessage);
          }
          sink.add(chunk);
          received += chunk.length;

          if (onProgress != null && expectedTotal > 0) {
            final now = DateTime.now();
            final percent = received / expectedTotal;
            if (percent >= 1.0 ||
                now.difference(lastUiUpdate).inMilliseconds >= 200) {
              lastUiUpdate = now;
              onProgress(percent.clamp(0.0, 0.99));
            }
          }
        }
      }

      await sink.flush();
      await sink.close();

      // Validar que el archivo descargado no esté corrupto o vacío (mínimo 50 KB)
      _validateDownloadedFile(file, totalBytes);

    } catch (e) {
      try { await sink.close(); } catch (_) {}
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }

    onProgress?.call(1.0);
    return filePath;
  }



  /// User-Agent para las peticiones de bytes a googlevideo.com.
  ///
  /// Historial: aquí había un User-Agent de Chrome 96 de escritorio (de 2021),
  /// y eso producía un `HttpException: HTTP 403` en download_errors.log con
  /// metadata y manifest funcionando correctamente — el fallo estaba sólo en
  /// la descarga de bytes. La hipótesis original era "el UA tiene que
  /// coincidir con el cliente que pidió el manifest", y bajo esa teoría este
  /// valor se puso al de los clientes `android`/`androidSdkless`.
  ///
  /// Test A/B (docs/investigacion_muro_antibot.md, 2026-07-29) mostró que esa
  /// teoría era incompleta: con este mismo UA (Pixel 5 / Chrome 120, el de
  /// `main`), un manifest resuelto por `android`/`androidSdkless` seguía dando
  /// 403 en bytes 2/2 (Test A), pero el mismo vídeo con manifest resuelto por
  /// `[androidVr, safari]` completaba 2/2 con el UA sin cambiar (Test B). O
  /// sea: el UA no era la variable que importaba — importa el CLIENTE que
  /// resolvió el manifest, ver `_clientFallbacks`. Este valor queda como está
  /// (coincide con el de `main`, y Test B confirma que funciona bien con
  /// `androidVr`/`safari`); el fix real está en el orden de `_clientFallbacks`
  /// y en que `downloadVideoWithAudio` escale de cliente ante un 403-en-bytes
  /// en vez de reintentar con el mismo.
  static const String _streamUserAgent =
      'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  void _addHeaders(HttpClientRequest request) {
    request.headers.add('User-Agent', _streamUserAgent);
    request.headers.add('Accept', '*/*');
    request.headers.add('Accept-Encoding', 'identity');
    request.headers.add('Connection', 'keep-alive');
  }

  void _validateDownloadedFile(File file, int expectedBytes) {
    if (!file.existsSync() || file.lengthSync() < 1000) {
      try {
        file.deleteSync();
      } catch (_) {}
      throw Exception(
        'Archivo descargado inválido (demasiado pequeño). Intenta de nuevo.',
      );
    }

    if (expectedBytes > 0) {
      final actual = file.lengthSync();
      if (actual < expectedBytes * 0.9) {
        try {
          file.deleteSync();
        } catch (_) {}
        throw Exception(
          'Descarga incompleta ($actual / $expectedBytes bytes).',
        );
      }
    }
  }

  bool _isRateLimitError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('rate limiting') ||
        msg.contains('requestlimitexceeded') ||
        msg.contains('429');
  }

  ({String title, String artist}) _parseTitleAndArtist(
    String originalTitle,
    String author,
  ) {
    String artist = author;
    String cleanTitle = originalTitle;

    if (originalTitle.contains(' - ')) {
      final parts = originalTitle.split(' - ');
      artist = parts[0].trim();
      cleanTitle = parts.sublist(1).join(' - ').trim();
    } else if (originalTitle.contains(' – ')) {
      final parts = originalTitle.split(' – ');
      artist = parts[0].trim();
      cleanTitle = parts.sublist(1).join(' – ').trim();
    }

    return (title: cleanTitle, artist: artist);
  }

  String _resolveThumbnailUrl(Video video, VideoId videoId) {
    // mqdefault.jpg (mediumResUrl) is native 16:9 and always available.
    // highResUrl (hqdefault.jpg) is a 4:3 canvas — for videos whose uploaded
    // thumbnail is itself square album art, YouTube pillarboxes it into that
    // 4:3 canvas, which a downstream square crop can't fully remove (BoxFit.cover
    // only trims sides, never the padding baked into the pixels). 16:9 avoids that.
    return video.thumbnails.mediumResUrl;
  }

  Future<String> downloadThumbnail(String videoId, String url) async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final thumbDir = Directory('${docDir.path}/thumbnails');

      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final filePath = '${thumbDir.path}/$videoId.jpg';
      final file = File(filePath);

      if (file.existsSync() && file.lengthSync() > 0) {
        return filePath;
      }

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>(
            [],
            (prev, chunk) => prev..addAll(chunk),
          );
          await file.writeAsBytes(bytes);
          return filePath;
        }
      } finally {
        client.close();
      }
      return '';
    } catch (e) {
      print('Error downloading thumbnail: $e');
      return '';
    }
  }

  /// Searches YouTube for a song by title and artist, downloads the best
  /// match based on duration similarity, and returns the result with the
  /// caller's metadata injected instead of YouTube's parsed metadata.
  ///
  /// This is the core bridge for Spotify → YouTube downloads.
  Future<Map<String, dynamic>> searchAndDownload({
    required String title,
    required String artist,
    required int expectedDurationMs,
    String? spotifyThumbnailUrl,
    void Function(String title)? onMetadata,
    void Function(double)? onProgress,
    void Function(String phase)? onPhase,
    bool Function()? isCancelled,
  }) async {
    onPhase?.call('metadata');
    onMetadata?.call(title);

    final yt = YoutubeExplode();
    try {
      // Search YouTube with "artist - title" query
      final query = '$artist - $title';

      // Este método NO reutiliza `searchVideos`: hace su propia búsqueda porque
      // necesita los `Video` crudos para emparejar por duración. Eso significaba
      // que se saltaba las tres protecciones que `searchVideos` sí tiene —
      // timeout, circuit breaker compartido y check de cancelación — pese a ser
      // el primer paso de TODA descarga de Spotify. Sin timeout, un socket
      // colgado aquí congelaba la descarga hasta el attemptBudget de 10 minutos;
      // sin respetar el cooldown, disparaba peticiones justo cuando YouTube ya
      // estaba bloqueando, realimentando el bloqueo que el breaker existe para
      // cortar.
      if (isCancelled != null && isCancelled()) {
        throw Exception(cancelledMessage);
      }
      await _respectGlobalCooldown('searchAndDownload', isCancelled: isCancelled);
      final searchResults = await _withTimeout(
        yt.search.search(query),
        'La búsqueda de "$query"',
        _requestTimeout,
      );

      if (searchResults.isEmpty) {
        throw Exception('No se encontraron resultados en YouTube para: "$query"');
      }

      // Find the best match by duration similarity
      final expectedDurationSec = (expectedDurationMs / 1000).round();
      Video? bestMatch;
      int bestDiff = 999999;

      for (final video in searchResults.take(10)) {
        final videoDuration = video.duration?.inSeconds ?? 0;
        if (videoDuration == 0) continue;

        final diff = (videoDuration - expectedDurationSec).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          bestMatch = video;
          // Perfect match — stop searching
          if (diff <= 3) break;
        }
      }

      // If no match within 30 seconds, fall back to the first result
      bestMatch ??= searchResults.first;

      if (bestDiff > 30 && searchResults.isNotEmpty) {
        // Use first result as fallback if duration match is poor
        bestMatch = searchResults.first;
      }

      final videoUrl = 'https://www.youtube.com/watch?v=${bestMatch.id.value}';

      // Cache the metadata for the download phase
      _metadataCache[bestMatch.id.value] = _CachedVideoMetadata(
        title: title,
        artist: artist,
        duration: Duration(milliseconds: expectedDurationMs),
        thumbnailUrl: spotifyThumbnailUrl ?? _resolveThumbnailUrl(bestMatch, bestMatch.id),
        cachedAt: DateTime.now(),
      );

      // Download using existing infrastructure
      final result = await downloadVideoWithAudio(
        videoUrl,
        onMetadata: onMetadata,
        onProgress: onProgress,
        onPhase: onPhase,
        isCancelled: isCancelled,
      );

      // Override with Spotify metadata for higher accuracy
      result['title'] = title;
      result['artist'] = artist;
      result['duration'] = Duration(milliseconds: expectedDurationMs);

      // Download Spotify thumbnail if available (higher quality than YouTube)
      if (spotifyThumbnailUrl != null && spotifyThumbnailUrl.isNotEmpty) {
        final spotifyArt = await downloadThumbnail(
          result['videoId'] as String,
          spotifyThumbnailUrl,
        );
        if (spotifyArt.isNotEmpty) {
          result['artPath'] = spotifyArt;
        }
      }

      return result;
    } catch (e) {
      if (_isRateLimitError(e)) rethrow;
      // La cancelación se propaga sin envolver. `isCancellationError` la
      // reconocería igual dentro del wrapper (busca por substring), pero
      // envolverla la convierte en un mensaje de error de búsqueda, y el registro
      // de un fallo de búsqueda es justo lo que no queremos cuando el usuario
      // simplemente canceló.
      if (isCancellationError(e)) rethrow;
      throw Exception('Error buscando "$artist - $title" en YouTube: ${e.toString()}');
    } finally {
      yt.close();
    }
  }

  void dispose() {}
}
