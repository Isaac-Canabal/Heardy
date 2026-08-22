import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Traduce letras línea por línea vía MyMemory (api.mymemory.translated.net),
/// una API pública gratuita sin API key — mismo estilo que LyricsService/LRCLIB.
/// Cachea el resultado en disco para que abrir la traducción una segunda vez
/// no vuelva a golpear la red.
class TranslationService {
  static final TranslationService instance = TranslationService._init();
  TranslationService._init();

  static const int _maxConcurrentRequests = 4;

  Future<String> _getCacheFilePath(String songId, String targetLang) async {
    final docDir = await getApplicationDocumentsDirectory();
    final lyricsDir = Directory('${docDir.path}/lyrics');
    if (!await lyricsDir.exists()) {
      await lyricsDir.create(recursive: true);
    }
    return '${lyricsDir.path}/$songId.translated_$targetLang.json';
  }

  /// Traduce [lines] al idioma [targetLang] ('es'/'en'), asumiendo que el
  /// idioma original es el otro de los dos soportados por la app (heurística
  /// simple: no hay forma barata de detectar el idioma real de una letra sin
  /// otro servicio). Letras en un tercer idioma se traducirán mal, pero no
  /// rompen nada — el fallback por línea es el texto original.
  Future<List<String>> translateLines({
    required String songId,
    required List<String> lines,
    required String targetLang,
  }) async {
    final cachePath = await _getCacheFilePath(songId, targetLang);
    final cacheFile = File(cachePath);
    if (await cacheFile.exists()) {
      try {
        final cached = jsonDecode(await cacheFile.readAsString()) as List<dynamic>;
        if (cached.length == lines.length) {
          return cached.map((e) => e as String).toList();
        }
      } catch (e) {
        print('Error leyendo cache de traducción: $e');
      }
    }

    final sourceLang = targetLang == 'es' ? 'en' : 'es';
    final translated = List<String>.filled(lines.length, '');

    for (var start = 0; start < lines.length; start += _maxConcurrentRequests) {
      final end = (start + _maxConcurrentRequests < lines.length)
          ? start + _maxConcurrentRequests
          : lines.length;
      final chunk = List.generate(end - start, (i) => start + i);
      await Future.wait(chunk.map((i) async {
        final line = lines[i];
        if (line.trim().isEmpty) {
          translated[i] = line;
          return;
        }
        translated[i] = await _translateOne(line, sourceLang, targetLang) ?? line;
      }));
    }

    try {
      await cacheFile.writeAsString(jsonEncode(translated));
    } catch (e) {
      print('Error escribiendo cache de traducción: $e');
    }

    return translated;
  }

  Future<String?> _translateOne(String text, String sourceLang, String targetLang) async {
    try {
      final uri = Uri.https('api.mymemory.translated.net', '/get', {
        'q': text,
        'langpair': '$sourceLang|$targetLang',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final translatedText =
          json['responseData']?['translatedText'] as String?;
      if (translatedText == null || translatedText.isEmpty) return null;
      return translatedText;
    } catch (e) {
      print('Error traduciendo línea: $e');
      return null;
    }
  }
}
