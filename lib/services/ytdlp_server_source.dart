import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'download_source.dart';

/// Cliente HTTP del microservidor yt-dlp propio (`server/` en este repo).
///
/// Usa el paquete `http`, que ya era dependencia por `lyrics_service.dart`.
/// Toda llamada lleva timeout explícito: sin él una petición a un servidor
/// que acepta la conexión pero no responde cuelga para siempre y sin registro
/// (el mismo error que la capa de descargas anterior arrastró durante meses).
class YtdlpServerSource implements DownloadSource {
  /// Metadata/búsqueda: rápido o no sirve, la UI está esperando.
  static const _metadataTimeout = Duration(seconds: 30);

  /// Expandir una playlist larga da bastante más trabajo al servidor.
  static const _playlistTimeout = Duration(seconds: 120);

  /// El servidor baja el vídeo antes de responder, así que la primera cabecera
  /// puede tardar. No cubre la transferencia entera, solo el arranque.
  static const _audioHeaderTimeout = Duration(minutes: 5);

  /// Silencio máximo entre trozos ya empezada la transferencia. Corta una
  /// conexión colgada sin abortar una descarga lenta pero viva.
  static const _audioIdleTimeout = Duration(seconds: 90);

  final String Function() _baseUrlProvider;
  final String Function() _apiKeyProvider;
  final http.Client Function() _clientFactory;

  YtdlpServerSource({
    required String Function() baseUrl,
    required String Function() apiKey,
    http.Client Function()? clientFactory,
  })  : _baseUrlProvider = baseUrl,
        _apiKeyProvider = apiKey,
        _clientFactory = clientFactory ?? (() => http.Client());

  bool get isConfigured => _normalizedBase() != null;

  /// Normaliza lo que el usuario escribió en Ajustes: acepta `192.168.1.5:8080`
  /// tanto como `http://192.168.1.5:8080/`, porque nadie escribe el esquema.
  String? _normalizedBase() {
    var raw = _baseUrlProvider().trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    final parsed = Uri.tryParse(raw);
    if (parsed == null || parsed.host.isEmpty) return null;
    return raw;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _normalizedBase();
    if (base == null) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.notConfigured,
        'No hay servidor de descargas configurado',
      );
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> _headers({bool json = false}) => {
        'X-Api-Key': _apiKeyProvider().trim(),
        if (json) 'Content-Type': 'application/json',
      };

  /// Traduce un fallo de transporte al tipo que la cola sabe interpretar.
  Never _rethrowAsSourceError(Object error) {
    if (error is DownloadSourceException) throw error;
    if (error is TimeoutException) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.network,
        'El servidor de descargas tardó demasiado en responder',
      );
    }
    if (error is SocketException || error is HttpException || error is HandshakeException) {
      throw DownloadSourceException(DownloadSourceErrorKind.network, error.toString());
    }
    throw DownloadSourceException(DownloadSourceErrorKind.network, error.toString());
  }

  /// Mapea el código HTTP al tipo de error. El 415 del servidor es
  /// deliberadamente distinto del 502: significa "este vídeo no tiene pista
  /// AAC", que es definitivo, mientras que el 502 sí merece reintento.
  void _checkStatus(int statusCode, String body) {
    if (statusCode >= 200 && statusCode < 300) return;
    final detail = _detailFrom(body);
    switch (statusCode) {
      case 401:
      case 403:
        throw DownloadSourceException(DownloadSourceErrorKind.unauthorized, detail);
      case 415:
        throw DownloadSourceException(DownloadSourceErrorKind.unsupportedMedia, detail);
      case 404:
        // El servidor reserva el 404 para lo definitivo: vídeo borrado,
        // privado, sólo para miembros, restringido por edad, o URL inválida.
        // Lo pasajero (su IP bloqueada, un corte de red) sale como 502.
        throw DownloadSourceException(DownloadSourceErrorKind.notFound, detail);
      case 400:
      case 422:
        throw DownloadSourceException(DownloadSourceErrorKind.notFound, detail);
      default:
        throw DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El servidor respondió $statusCode: $detail',
        );
    }
  }

  String _detailFrom(String body) {
    if (body.isEmpty) return 'sin detalle';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) {
        return decoded['detail'].toString();
      }
    } catch (_) {
      // Cuerpo no-JSON (p. ej. una página de error de un proxy intermedio).
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }

  Future<Map<String, dynamic>> _postJson(String path, Map<String, dynamic> body, Duration timeout) async {
    final client = _clientFactory();
    try {
      final response = await client
          .post(_uri(path), headers: _headers(json: true), body: jsonEncode(body))
          .timeout(timeout);
      _checkStatus(response.statusCode, response.body);
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<RemoteTrack> resolve(String url) async {
    final json = await _postJson('/resolve', {'url': url}, _metadataTimeout);
    return RemoteTrack.fromJson(json);
  }

  @override
  Future<RemotePlaylist> resolvePlaylist(String url) async {
    final json = await _postJson('/playlist', {'url': url}, _playlistTimeout);
    return RemotePlaylist.fromJson(json);
  }

  @override
  Future<List<RemoteTrack>> search(String query, {int limit = 20}) async {
    final client = _clientFactory();
    try {
      final response = await client
          .get(_uri('/search', {'q': query, 'limit': '$limit'}), headers: _headers())
          .timeout(_metadataTimeout);
      _checkStatus(response.statusCode, response.body);
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RemoteTrack.fromJson)
          .where((t) => t.id.isNotEmpty)
          .toList();
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<void> fetchAudio(
    String trackId,
    String destPath, {
    ProgressCallback? onProgress,
    CancellationCheck? isCancelled,
  }) async {
    final client = _clientFactory();
    final destFile = File(destPath);
    IOSink? sink;
    try {
      final request = http.Request('GET', _uri('/audio/$trackId'))
        ..headers.addAll(_headers());
      final response = await client.send(request).timeout(_audioHeaderTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        _checkStatus(response.statusCode, body);
      }

      final total = response.contentLength;
      var received = 0;

      await destFile.parent.create(recursive: true);
      sink = destFile.openWrite();

      // El timeout es por-trozo, no global: una descarga lenta pero viva no
      // debe morir, una conexión colgada sí.
      await for (final chunk in response.stream.timeout(_audioIdleTimeout)) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadSourceException(
            DownloadSourceErrorKind.cancelled,
            'Descarga cancelada',
          );
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      await sink.flush();
      await sink.close();
      sink = null;

      if (received == 0) {
        throw const DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El servidor devolvió una respuesta vacía',
        );
      }
      // Una transferencia cortada limpiamente a mitad llega aquí sin error de
      // socket; solo Content-Length delata que falta contenido.
      if (total != null && received < total) {
        throw DownloadSourceException(
          DownloadSourceErrorKind.network,
          'Transferencia incompleta: $received de $total bytes',
        );
      }
    } catch (e) {
      // El archivo parcial nunca debe sobrevivir: DownloadService lo pegaría
      // en la biblioteca del usuario como si fuera una canción.
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await destFile.exists()) await destFile.delete();
      } catch (_) {}
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<DownloadSourceStatus> probe() async {
    if (_normalizedBase() == null) {
      return const DownloadSourceStatus(
        reachable: false,
        authenticated: false,
        version: null,
        potProviderReachable: false,
        detail: 'No hay dirección de servidor configurada',
      );
    }

    final client = _clientFactory();
    try {
      // /health no pide autenticación a propósito, para poder distinguir
      // "servidor apagado" de "clave incorrecta".
      final health = await client.get(_uri('/health')).timeout(const Duration(seconds: 10));
      if (health.statusCode != 200) {
        return DownloadSourceStatus(
          reachable: false,
          authenticated: false,
          version: null,
          potProviderReachable: false,
          detail: 'El servidor respondió ${health.statusCode}',
        );
      }

      final json = jsonDecode(utf8.decode(health.bodyBytes)) as Map<String, dynamic>;
      final pot = json['potProvider'] as Map<String, dynamic>? ?? const {};
      final authRequired = json['authRequired'] == true;

      var authenticated = !authRequired;
      var detail = 'Conectado';
      if (authRequired) {
        // Una llamada autenticada barata es la única forma de saber si la
        // clave sirve, porque /health no la pide.
        final probe = await client
            .get(_uri('/search', {'q': 'heardy', 'limit': '1'}), headers: _headers())
            .timeout(const Duration(seconds: 20));
        authenticated = probe.statusCode != 401 && probe.statusCode != 403;
        if (!authenticated) detail = 'La clave de API no es válida';
      }

      if (authenticated && pot['reachable'] != true) {
        detail = 'Conectado, pero el proveedor de PO tokens no responde: '
            'la mayoría de descargas fallarán';
      }

      return DownloadSourceStatus(
        reachable: true,
        authenticated: authenticated,
        version: json['ytdlpVersion']?.toString(),
        potProviderReachable: pot['reachable'] == true,
        detail: detail,
      );
    } catch (e) {
      return DownloadSourceStatus(
        reachable: false,
        authenticated: false,
        version: null,
        potProviderReachable: false,
        detail: e is TimeoutException
            ? 'El servidor no respondió a tiempo'
            : 'No se pudo contactar con el servidor',
      );
    } finally {
      client.close();
    }
  }
}
