import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class LyricLine {
  final Duration time;
  final String text;
  LyricLine(this.time, this.text);
}

class LyricsService {
  static final LyricsService instance = LyricsService._init();
  LyricsService._init();

  Future<String> _getLyricsFilePath(String songId) async {
    final docDir = await getApplicationDocumentsDirectory();
    final lyricsDir = Directory('${docDir.path}/lyrics');
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return '${lyricsDir.path}/$songId.lrc';
  }

  /// Cleans title and artist names to match LRCLIB's database better
  String _cleanName(String text) {
    return text
        .replaceAll(RegExp(r'\((Official\s+)?(Video|Audio|Lyrics|Lyric\s+Video|HQ|HD)\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[(Official\s+)?(Video|Audio|Lyrics|Lyric\s+Video|HQ|HD)\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s-\sTopic$', caseSensitive: false), '')
        .trim();
  }

  /// Fetches and caches lyrics. Returns null if not found.
  Future<String?> getLyrics({
    required String songId,
    required String title,
    required String artist,
    required int durationSeconds,
  }) async {
    // 1. Check local file cache
    final localPath = await _getLyricsFilePath(songId);
    final localFile = File(localPath);
    if (await localFile.exists()) {
      final cachedLyrics = await localFile.readAsString();
      if (cachedLyrics.isNotEmpty) return cachedLyrics;
    }

    // 2. Fetch online from LRCLIB
    final cleanTitle = _cleanName(title);
    final cleanArtist = _cleanName(artist);

    // Endpoint 1: Exact get
    try {
      final getUri = Uri.parse('https://lrclib.net/api/get').replace(
        queryParameters: {
          'track_name': cleanTitle,
          'artist_name': cleanArtist,
          'duration': durationSeconds.toString(),
        },
      );

      final response = await http.get(getUri, headers: {
        'User-Agent': 'Heardy/1.0.0 (https://github.com/Isaac-Canabal/Heardy)'
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final lyrics = data['syncedLyrics'] as String? ?? data['plainLyrics'] as String? ?? '';
        if (lyrics.isNotEmpty) {
          await localFile.writeAsString(lyrics);
          return lyrics;
        }
      }
    } catch (e) {
      print('Exact match lookup on LRCLIB failed: $e');
    }

    // Endpoint 2: Search query fallback
    try {
      final searchUri = Uri.parse('https://lrclib.net/api/search').replace(
        queryParameters: {
          'q': '$cleanTitle $cleanArtist',
        },
      );

      final response = await http.get(searchUri, headers: {
        'User-Agent': 'Heardy/1.0.0 (https://github.com/Isaac-Canabal/Heardy)'
      }).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> results = jsonDecode(response.body);
        if (results.isNotEmpty) {
          // Check for a result that has synced or plain lyrics
          for (final item in results) {
            final lyrics = item['syncedLyrics'] as String? ?? item['plainLyrics'] as String? ?? '';
            if (lyrics.isNotEmpty) {
              await localFile.writeAsString(lyrics);
              return lyrics;
            }
          }
        }
      }
    } catch (e) {
      print('Search query fallback on LRCLIB failed: $e');
    }

    return null;
  }

  /// Parses .lrc styled string into LyricLines
  List<LyricLine> parseLrc(String lrcText) {
    final List<LyricLine> lines = [];
    final regExp = RegExp(r'^\[(\d+):(\d+)(?:\.(\d+))?\](.*)');

    for (final line in lrcText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final match = regExp.firstMatch(trimmed);
      if (match != null) {
        final min = int.parse(match.group(1)!);
        final sec = int.parse(match.group(2)!);
        final msStr = match.group(3) ?? '0';
        final ms = int.parse(msStr);
        final text = match.group(4)!.trim();

        // Convert centiseconds (2 digits) or milliseconds (3 digits) to ms
        final multiplier = msStr.length == 2 ? 10 : (msStr.length == 1 ? 100 : 1);
        final duration = Duration(
          minutes: min,
          seconds: sec,
          milliseconds: ms * multiplier,
        );
        lines.add(LyricLine(duration, text));
      }
    }

    lines.sort((a, b) => a.time.compareTo(b.time));
    return lines;
  }
}
