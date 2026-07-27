import 'dart:async';

import 'package:dart_ytmusic_api/yt_music.dart';
import 'youtube_service.dart';

/// Service wrapper for YouTube Music API (InnerTube) with fallback to youtube_explode_dart
/// This provides better reliability by using the official YouTube Music API
class YTMusicService {
  YTMusic? _ytmusic;
  final YoutubeService _youtubeService = YoutubeService();

  /// Techo de tiempo para cada llamada a `dart_ytmusic_api`.
  ///
  /// Igual que `youtube_explode_dart` (ver `_requestTimeout` en
  /// youtube_service.dart), `dart_ytmusic_api` 1.3.7 NO define un solo timeout en
  /// toda su librería: ni en `initialize()` ni en `getSong`/`getPlaylistVideos`/
  /// `searchSongs`. Si el socket se queda colgado —habitual en datos móviles, o
  /// cuando YouTube acepta la conexión pero no responde— el future nunca
  /// completa NI lanza.
  ///
  /// Eso era especialmente grave aquí porque esta clase es el path PRIMARIO de
  /// todas las operaciones, así que un cuelgue ocurría antes de que
  /// `YoutubeService` (que sí tiene timeouts) llegara a intervenir:
  ///
  /// - En `getPlaylistVideoIds`/`getVideoInfo`, invocados desde "Analizar
  ///   enlace", la UI se quedaba clavada en "Analizando..." para siempre, sin
  ///   error y sin nada en download_errors.log.
  /// - Peor: en `downloadVideoWithAudio` el priming de metadata (`getSong`)
  ///   corre DENTRO del path de descarga. Su `try/catch` no sirve de nada
  ///   frente a un cuelgue, porque un future que nunca completa no lanza. Lo
  ///   único que acababa cortando era el `attemptBudget` de 10 minutos de
  ///   `_processQueueItem`, dos veces — 20 minutos de descarga "colgada".
  ///
  /// Con esto, un socket muerto se convierte en un TimeoutException rápido, que
  /// el `catch` existente ya trata como "falló la API primaria" y degrada al
  /// fallback de `YoutubeService` como estaba previsto.
  static const Duration _apiTimeout = Duration(seconds: 20);

  Future<T> _withTimeout<T>(Future<T> future, String what) {
    return future.timeout(
      _apiTimeout,
      onTimeout: () => throw TimeoutException(
        '$what (YTMusic API) no respondió en ${_apiTimeout.inSeconds}s',
      ),
    );
  }

  /// Initialize the YouTube Music API.
  ///
  /// El instance field se asigna sólo si `initialize()` completa. Antes se
  /// asignaba primero (`_ytmusic = YTMusic(); await _ytmusic!.initialize();`),
  /// así que si la inicialización fallaba, `_ytmusic` quedaba no-nulo pero sin
  /// inicializar — y como el guard es `if (_ytmusic == null)`, ninguna llamada
  /// posterior volvía a intentarlo: la instancia quedaba permanentemente rota
  /// para el resto de la vida del proceso, degradando siempre al fallback.
  Future<void> initialize() async {
    if (_ytmusic != null) return;
    final instance = YTMusic();
    await _withTimeout(instance.initialize(), 'La inicialización');
    _ytmusic = instance;
  }

  /// Get video info using YouTube Music API (primary) with fallback to youtube_explode_dart
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    try {
      await initialize();
      
      // Extract video ID from URL
      final videoId = _extractVideoId(url);
      if (videoId == null) {
        throw Exception('Invalid YouTube URL');
      }
      
      print('[YTMusicService] Trying YouTube Music API for video $videoId');
      
      // Try YouTube Music API first
      final song = await _withTimeout(
        _ytmusic!.getSong(videoId),
        'La consulta de metadata',
      );

      print('[YTMusicService] Success with YouTube Music API');
      return _convertYTMusicToMap(song, videoId);
      
    } catch (e) {
      print('[YTMusicService] YouTube Music API failed: $e');
      print('[YTMusicService] Falling back to youtube_explode_dart');
      
      // Fallback to youtube_explode_dart
      try {
        return await _youtubeService.getVideoInfo(url);
      } catch (fallbackError) {
        print('[YTMusicService] Fallback also failed: $fallbackError');
        throw Exception('Error analizando el video: ${fallbackError.toString()}\n\nDetalles técnicos:\n${fallbackError.runtimeType}');
      }
    }
  }
  
  /// Get playlist video IDs using YouTube Music API with fallback.
  ///
  /// [isCancelled] se propaga al fallback de `YoutubeService`, que es el que
  /// puede tardar de verdad (scraper propio paginado + expansión vía
  /// youtube_explode_dart). El path primario de aquí es una sola petición ya
  /// acotada por `_apiTimeout`, así que no necesita poder interrumpirse.
  Future<List<String>> getPlaylistVideoIds(
    String url, {
    bool Function()? isCancelled,
    bool interactive = false,
  }) async {
    try {
      await initialize();
      
      final playlistId = _extractPlaylistId(url);
      if (playlistId == null) {
        throw Exception('Invalid YouTube playlist URL');
      }
      
      print('[YTMusicService] Trying YouTube Music API for playlist $playlistId');
      
      final videos = await _withTimeout(
        _ytmusic!.getPlaylistVideos(playlistId),
        'La consulta de la lista',
      );

      if (videos.isNotEmpty) {
        print('[YTMusicService] Success with YouTube Music API - ${videos.length} videos');
        return videos.map((v) => v.videoId).toList();
      }
      
      throw Exception('Playlist not found in YouTube Music API');
    } catch (e) {
      print('[YTMusicService] YouTube Music API failed: $e');
      print('[YTMusicService] Falling back to youtube_explode_dart');
      
      // Fallback to youtube_explode_dart
      try {
        return await _youtubeService.getPlaylistVideoIds(
          url,
          isCancelled: isCancelled,
          interactive: interactive,
        );
      } catch (fallbackError) {
        // La cancelación se propaga tal cual: envolverla haría que
        // `YoutubeService.isCancellationError` siguiera reconociéndola por el
        // texto, pero DownloadProvider la registraría como "Error cargando la
        // lista" en download_errors.log, que es justo lo que se quitó del path
        // de descarga.
        if (YoutubeService.isCancellationError(fallbackError)) rethrow;
        print('[YTMusicService] Fallback also failed: $fallbackError');
        throw Exception('Error cargando la lista: ${fallbackError.toString()}');
      }
    }
  }
  
  /// Search videos using YouTube Music API with fallback
  Future<List<YouTubeSearchResult>> searchVideos(String query, {int maxResults = 20}) async {
    try {
      await initialize();
      
      print('[YTMusicService] Trying YouTube Music API for search: $query');
      
      final results = await _withTimeout(
        _ytmusic!.searchSongs(query),
        'La búsqueda',
      );

      if (results.isNotEmpty) {
        print('[YTMusicService] Success with YouTube Music API - ${results.length} results');
        return results.take(maxResults).map((song) {
          return YouTubeSearchResult(
            videoId: song.videoId,
            title: song.name,
            artist: _parseArtists(song),
            duration: _parseDuration(song),
            thumbnailUrl: _parseThumbnail(song),
            url: 'https://www.youtube.com/watch?v=${song.videoId}',
          );
        }).toList();
      }
      
      throw Exception('No results from YouTube Music API');
    } catch (e) {
      print('[YTMusicService] YouTube Music API failed: $e');
      print('[YTMusicService] Falling back to youtube_explode_dart');
      
      // Fallback to youtube_explode_dart
      try {
        return await _youtubeService.searchVideos(query, maxResults: maxResults);
      } catch (fallbackError) {
        print('[YTMusicService] Fallback also failed: $fallbackError');
        throw Exception('Error buscando videos: ${fallbackError.toString()}');
      }
    }
  }
  
  /// Download video using youtube_explode_dart (YTMusic API doesn't support downloads).
  Future<Map<String, dynamic>> downloadVideoWithAudio(
    String url, {
    void Function(String title)? onMetadata,
    void Function(double)? onProgress,
    void Function(String phase)? onPhase,
    bool Function()? isCancelled,
  }) async {
    // Try to prime YoutubeService's metadata cache via the YTMusic InnerTube API
    // first — it hits a structured JSON endpoint, not the scraped /watch page
    // youtube_explode_dart's videos.get() depends on, which YouTube can serve a
    // "sign in to confirm you're not a bot" wall on and get misread as the video
    // being unavailable. downloadVideoWithAudio checks this cache before falling
    // back to that fragile scrape, so priming it here (when it succeeds) avoids
    // hitting it at all. Best-effort: any failure here just falls through to the
    // existing behavior unchanged.
    try {
      final videoId = _extractVideoId(url);
      if (videoId != null) {
        await initialize();
        final song = await _withTimeout(
          _ytmusic!.getSong(videoId),
          'El priming de metadata',
        );
        YoutubeService.primeMetadataCache(
          videoId,
          title: song.name,
          artist: song.artist.name,
          duration: Duration(seconds: song.duration),
          thumbnailUrl: song.thumbnails.isNotEmpty ? song.thumbnails.last.url : '',
        );
        print('[YTMusicService] Primed metadata via YTMusic API for $videoId — skips the fragile watch-page scrape');
      }
    } catch (e) {
      print('[YTMusicService] Could not prime metadata via YTMusic API, will fall back to youtube_explode_dart: $e');
    }

    print('[YTMusicService] Using youtube_explode_dart for download');
    return await _youtubeService.downloadVideoWithAudio(
      url,
      onMetadata: onMetadata,
      onProgress: onProgress,
      onPhase: onPhase,
      isCancelled: isCancelled,
    );
  }
  
  /// Search and download - delegate to youtube_explode_dart
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
    // Delegate to youtube_explode_dart for search and download functionality
    return await _youtubeService.searchAndDownload(
      title: title,
      artist: artist,
      expectedDurationMs: expectedDurationMs,
      spotifyThumbnailUrl: spotifyThumbnailUrl,
      onMetadata: onMetadata,
      onProgress: onProgress,
      onPhase: onPhase,
      isCancelled: isCancelled,
    );
  }
  
  /// Extract video ID from YouTube URL
  String? _extractVideoId(String url) {
    final regex = RegExp(r'(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/\s]{11})');
    final match = regex.firstMatch(url);
    return match?.group(1);
  }
  
  /// Extract playlist ID from YouTube URL
  String? _extractPlaylistId(String url) {
    final regex = RegExp(r'[?&]list=([^&]+)');
    final match = regex.firstMatch(url);
    return match?.group(1);
  }
  
  /// Convert YTMusic song to map format compatible with existing code
  Map<String, dynamic> _convertYTMusicToMap(dynamic song, String videoId) {
    return {
      'videoId': videoId,
      'title': song.name,
      'artist': _parseArtists(song),
      'duration': _parseDuration(song),
      'thumbnailUrl': _parseThumbnail(song),
    };
  }
  
  /// Parse the artist from a SongFull/SongDetailed.
  ///
  /// dart_ytmusic_api expone `artist` (un único `ArtistBasic`), NO `artists`.
  /// Con `song.artists` esto lanzaba NoSuchMethodError en cada llamada, el catch
  /// se lo tragaba y TODO lo que pasara por getVideoInfo/searchVideos salía como
  /// "Unknown Artist". El priming de la caché en downloadVideoWithAudio ya usaba
  /// el campo correcto, que es lo que delataba el error.
  String _parseArtists(dynamic song) {
    try {
      final name = song.artist?.name;
      if (name is String && name.isNotEmpty) return name;
      return 'Unknown Artist';
    } catch (e) {
      return 'Unknown Artist';
    }
  }

  /// Parse duration from song object. dart_ytmusic_api la da en SEGUNDOS
  /// (`duration`), no en milisegundos — no existe ningún `durationMs`, así que
  /// leerlo devolvía siempre 0 y todas las duraciones salían 0:00.
  Duration _parseDuration(dynamic song) {
    try {
      final seconds = song.duration;
      if (seconds is int && seconds > 0) return Duration(seconds: seconds);
      return Duration.zero;
    } catch (e) {
      return Duration.zero;
    }
  }
  
  /// Parse thumbnail from song object
  String _parseThumbnail(dynamic song) {
    try {
      if (song.thumbnails != null && song.thumbnails.isNotEmpty) {
        return song.thumbnails.last.url;
      }
      return '';
    } catch (e) {
      return '';
    }
  }
  
  void dispose() {
    _youtubeService.dispose();
  }
}
