import 'dart:io';
import 'dart:async';
import 'dart:convert';
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

class YoutubeService {
  YoutubeService();

  static final Map<String, _CachedVideoMetadata> _metadataCache = {};

  /// Preview for the UI — metadata only, no manifest (avoids burning stream URLs).
  Future<Map<String, dynamic>> getVideoInfo(String url) async {
    final yt = YoutubeExplode();
    try {
      final videoId = VideoId(url);
      final video = await yt.videos.get(videoId);
      final parsed = _parseTitleAndArtist(video.title, video.author);
      final thumbnailUrl = _resolveThumbnailUrl(video, videoId);

      _metadataCache[videoId.value] = _CachedVideoMetadata(
        title: parsed.title,
        artist: parsed.artist,
        duration: video.duration ?? Duration.zero,
        thumbnailUrl: thumbnailUrl,
        cachedAt: DateTime.now(),
      );

      return {
        'videoId': videoId.value,
        'title': parsed.title,
        'artist': parsed.artist,
        'duration': video.duration ?? Duration.zero,
        'thumbnailUrl': thumbnailUrl,
      };
    } catch (e) {
      throw Exception('Error analizando el video: ${e.toString()}');
    } finally {
      yt.close();
    }
  }

  /// Downloads audio using a fresh YoutubeExplode session with alternative clients
  /// that bypass the YouTube "n-parameter" throttling.
  Future<Map<String, dynamic>> downloadVideoWithAudio(
    String url, {
    void Function(String title)? onMetadata,
    void Function(double)? onProgress,
    void Function(String phase)? onPhase,
    bool Function()? isCancelled,
  }) async {
    final videoId = VideoId(url);
    final cached = _metadataCache[videoId.value];

    // Use alternative clients that provide non-throttled stream URLs.
    // androidVr and safari clients serve URLs where the "n" parameter
    // is already pre-resolved or not required, avoiding 50KB/s throttling.
    final yt = YoutubeExplode();
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
        final video = await yt.videos.get(videoId);
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

      // Try alternative clients first — these bypass n-parameter throttling.
      // Fall back to defaults if they fail.
      StreamManifest manifest;
      try {
        manifest = await yt.videos.streamsClient.getManifest(
          videoId,
          ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
        );
      } catch (_) {
        // Fallback: let the library pick its default clients
        manifest = await yt.videos.streamsClient.getManifest(videoId);
      }

      final selectedStream = _selectBestAudioStream(manifest);

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
      );

      final localThumbnailPath = await thumbnailDownloadFuture;

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
      if (_isRateLimitError(e)) rethrow;
      throw Exception('Error descargando el audio: ${e.toString()}');
    } finally {
      yt.close();
    }
  }

  Future<List<String>> getPlaylistVideoIds(String url) async {
    try {
      final customIds = await _customScrapePlaylist(url);
      if (customIds.isNotEmpty) {
        return customIds;
      }
    } catch (e) {
      print('Custom playlist scraper failed, falling back to YoutubeExplode: $e');
    }

    final yt = YoutubeExplode();
    try {
      final playlistId = PlaylistId(url);
      final List<String> videoIds = [];

      await for (final video in yt.playlists.getVideos(playlistId)) {
        if (video.id.value.isNotEmpty) {
          videoIds.add(video.id.value);
        }
      }

      return videoIds;
    } catch (e) {
      throw Exception(
        'Error cargando la lista de reproducción: ${e.toString()}',
      );
    } finally {
      yt.close();
    }
  }

  Future<List<String>> _customScrapePlaylist(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    final List<String> videoIds = [];
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
      final response = await request.close();
      final html = await response.transform(utf8.decoder).join();
      
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
        final postResponse = await postRequest.close();
        final postHtml = await postResponse.transform(utf8.decoder).join();
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
      final m4a = directAudio
          .where((s) => s.container.name == 'm4a' || s.container.name == 'mp4')
          .toList();
      if (m4a.isNotEmpty) {
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

  /// Downloads audio using parallel HTTP Range requests (4 concurrent workers).
  /// This dramatically improves throughput vs a single sequential connection.
  Future<String> _downloadViaParallelChunks(
    AudioOnlyStreamInfo streamInfo, {
    void Function(double)? onProgress,
    bool Function()? isCancelled,
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
    final url = streamInfo.url;

    // Check if already fully downloaded
    if (file.existsSync()) {
      final existing = file.lengthSync();
      if (totalBytes > 0 && existing >= totalBytes) {
        onProgress?.call(1.0);
        return filePath;
      }
      file.deleteSync();
    }

    // Unknown size — fall back to single sequential download
    if (totalBytes <= 0) {
      return _downloadSequential(url, file, filePath, onProgress, isCancelled);
    }

    // Build list of (start, end) chunk ranges (1 MB each)
    const int chunkSize = 1024 * 1024;
    final chunks = <(int, int)>[];
    for (int start = 0; start < totalBytes; start += chunkSize) {
      final end = (start + chunkSize - 1).clamp(0, totalBytes - 1);
      chunks.add((start, end));
    }

    // Download all chunks concurrently into memory, then write sequentially.
    // Using 4 concurrent HTTP connections.
    const int concurrency = 4;
    bool cancelled = false;
    Object? firstError;
    final bytesReceived = [0];
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> downloadChunk((int, int) chunk) async {
      final (start, end) = chunk;
      final chunkBytes = await _downloadChunkWithRetries(
        url,
        start,
        end,
        isCancelled: () {
          if (isCancelled != null && isCancelled()) {
            cancelled = true;
            return true;
          }
          return cancelled;
        },
      );

      if (cancelled) return;

      // Write chunk at its exact offset using RandomAccessFile
      final raf2 = await file.open(mode: FileMode.append);
      try {
        await raf2.setPosition(start);
        await raf2.writeFrom(chunkBytes);
      } finally {
        await raf2.close();
      }

      bytesReceived[0] += chunkBytes.length;

      if (onProgress != null) {
        final now = DateTime.now();
        final percent = bytesReceived[0] / totalBytes;
        if (percent >= 1.0 ||
            now.difference(lastUiUpdate).inMilliseconds >= 200) {
          lastUiUpdate = now;
          onProgress(percent.clamp(0.0, 0.99));
        }
      }
    }

    // Process chunks with limited concurrency (semaphore pattern)
    int chunkIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (cancelled) return;
        int myIndex;
        // Atomically grab the next chunk index
        myIndex = chunkIndex++;
        if (myIndex >= chunks.length) return;

        try {
          await downloadChunk(chunks[myIndex]);
        } catch (e) {
          firstError ??= e;
          cancelled = true;
          return;
        }
      }
    }

    // Launch workers concurrently
    await Future.wait(List.generate(concurrency, (_) => worker()));

    if (cancelled) {
      try {
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
      if (firstError != null) throw firstError!;
      throw Exception('Descarga cancelada por el usuario');
    }

    _validateDownloadedFile(file, totalBytes);
    onProgress?.call(1.0);
    return filePath;
  }

  /// Fallback: sequential stream download for when totalBytes is unknown.
  Future<String> _downloadSequential(
    Uri url,
    File file,
    String filePath,
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  ) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    final sink = file.openWrite();
    var received = 0;
    var lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      final request = await client.getUrl(url);
      _addHeaders(request);
      final response = await request.close().timeout(const Duration(seconds: 20));

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength;

      await for (final chunk in response.timeout(
        const Duration(seconds: 60),
        onTimeout: (eventSink) => eventSink.addError(
          TimeoutException('Sin datos del servidor durante 60s'),
        ),
      )) {
        if (isCancelled != null && isCancelled()) {
          throw Exception('Descarga cancelada por el usuario');
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

      await sink.flush();
      await sink.close();
    } catch (e) {
      await sink.close();
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

  /// Downloads a single byte range chunk with automatic retries.
  Future<List<int>> _downloadChunkWithRetries(
    Uri url,
    int start,
    int end, {
    bool Function()? isCancelled,
    int maxRetries = 4,
  }) async {
    Exception? lastError;

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      if (isCancelled != null && isCancelled()) {
        throw Exception('Descarga cancelada por el usuario');
      }

      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 20);

      try {
        final request = await client.getUrl(url);
        request.followRedirects = true;
        request.maxRedirects = 5;
        request.headers.add('Range', 'bytes=$start-$end');
        _addHeaders(request);

        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );

        if (response.statusCode != 200 && response.statusCode != 206) {
          throw HttpException('HTTP ${response.statusCode}');
        }

        final bytes = await response.fold<List<int>>(
          [],
          (prev, chunk) => prev..addAll(chunk),
        ).timeout(const Duration(seconds: 60));

        // Validate chunk integrity
        final expected = end - start + 1;
        if (bytes.length != expected) {
          throw Exception(
            'Chunk incompleto: recibidos ${bytes.length} de $expected bytes',
          );
        }

        return bytes;
      } on Exception catch (e) {
        lastError = e;
        if (attempt < maxRetries && (isCancelled == null || !isCancelled())) {
          // Exponential backoff: 1s, 2s, 4s
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
      } finally {
        client.close();
      }
    }

    throw lastError ?? Exception('No se pudo descargar el chunk');
  }

  void _addHeaders(HttpClientRequest request) {
    request.headers.add(
      'User-Agent',
      'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
    );
    request.headers.add('Accept', '*/*');
    request.headers.add('Accept-Language', 'en-US,en;q=0.9');
    request.headers.add('Origin', 'https://www.youtube.com');
    request.headers.add('Referer', 'https://www.youtube.com/');
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
    if (video.thumbnails.highResUrl.isNotEmpty) {
      return video.thumbnails.highResUrl;
    }
    if (video.thumbnails.mediumResUrl.isNotEmpty) {
      return video.thumbnails.mediumResUrl;
    }
    return 'https://img.youtube.com/vi/${videoId.value}/hqdefault.jpg';
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

  void dispose() {}
}
