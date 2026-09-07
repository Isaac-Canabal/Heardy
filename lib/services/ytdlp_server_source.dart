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
  /// Búsqueda: la UI está esperando, pero fallar antes de tiempo es peor que
  /// esperar — ver [_resolveTimeout].
  static const _searchTimeout = Duration(seconds: 60);

  /// Resolver un vídeo. **Eran 30 s y era demasiado poco**, con un fallo que
  /// parecía otra cosa: el servidor oficial corre en un plan gratuito con
  /// ~0,1 vCPU y además se duerme tras un rato inactivo. `/health` es trivial
  /// y contesta en menos de medio segundo (así que la app y el usuario lo ven
  /// perfectamente "activo"), pero `/resolve` ejecuta yt-dlp resolviendo el
  /// desafío de firma de YouTube en JavaScript, que es puro CPU: con esa
  /// cuota pasa de 30 s con normalidad, y arrancar en frío se suma encima.
  /// El resultado era un timeout presentado como "no se pudo contactar con el
  /// servidor" mientras el servidor estaba vivo y trabajando — el peor de los
  /// mensajes posibles, porque manda a investigar la red.
  ///
  /// Medido: el mismo `/resolve` contra un servidor local sin estrangular
  /// tarda 2,6-3,9 s. Todo lo que hay por encima de eso es la cuota de CPU
  /// del alojamiento, no el trabajo en sí.
  static const _resolveTimeout = Duration(seconds: 120);

  /// Expandir una playlist larga da bastante más trabajo al servidor.
  static const _playlistTimeout = Duration(seconds: 120);

  /// El servidor baja el vídeo antes de responder, así que la primera cabecera
  /// puede tardar. No cubre la transferencia entera, solo el arranque.
  static const _audioHeaderTimeout = Duration(minutes: 5);

  /// Silencio máximo entre trozos ya empezada la transferencia. Corta una
  /// conexión colgada sin abortar una descarga lenta pero viva.
  static const _audioIdleTimeout = Duration(seconds: 90);

  final String Function() _baseUrlProvider;
  final Future<String?> Function() _authTokenProvider;
  final String Function()? _apiKeyProvider;
  final http.Client Function() _clientFactory;

  /// [authToken] reemplaza la antigua clave de API compilada (Fase 2 del
  /// plan de seguridad, A1): es el token de ID de Firebase de quien inició
  /// sesión, mandado como `Authorization: Bearer`. `null`/vacío sin sesión —
  /// en ese caso las llamadas llegan sin autenticación y el servidor las
  /// rechaza con 401, que [DownloadSourceErrorKind.unauthorized] ya sabe
  /// interpretar.
  ///
  /// [apiKey] es el mecanismo viejo (`X-Api-Key`), opcional y sin usar por la
  /// app en sí (la clave compilada se quitó con este mismo cambio): sigue
  /// existiendo acá sólo porque el servidor mismo sigue aceptándolo para un
  /// servidor personal o de desarrollo (ver `server/app/auth.py`,
  /// `resolve_identity`), y es lo que exercita
  /// `test/download_live_integration_test.dart` contra un servidor local
  /// levantado con `HEARDY_API_KEY`. Cuando [authToken] resuelve un valor no
  /// vacío tiene prioridad — mismo orden que el servidor usa para decidir
  /// cuál de los dos mecanismos se está usando.
  YtdlpServerSource({
    required String Function() baseUrl,
    required Future<String?> Function() authToken,
    String Function()? apiKey,
    http.Client Function()? clientFactory,
  })  : _baseUrlProvider = baseUrl,
        _authTokenProvider = authToken,
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

  Future<Map<String, String>> _headers({bool json = false}) async {
    final token = await _authTokenProvider();
    final apiKey = _apiKeyProvider?.call().trim();
    return {
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token'
      else if (apiKey != null && apiKey.isNotEmpty)
        'X-Api-Key': apiKey,
      if (json) 'Content-Type': 'application/json',
    };
  }

  /// Traduce un fallo de transporte al tipo que la cola sabe interpretar.
  ///
  /// La última rama es un cajón de sastre: cualquier excepción que no sea
  /// ninguna de las anteriores acaba como `network`. Por eso el texto crudo
  /// viaja SIEMPRE dentro del mensaje (y al log) — sin él, un timeout, un
  /// fallo de TLS y un error de parseo se ven idénticos, y el usuario lee
  /// "el servidor no responde" con el servidor vivo.
  Never _rethrowAsSourceError(Object error) {
    if (error is DownloadSourceException) throw error;
    print('YtdlpServerSource: fallo de transporte (${error.runtimeType}) -> $error');
    if (error is TimeoutException) {
      throw const DownloadSourceException(
        DownloadSourceErrorKind.network,
        // Render duerme el servicio en el plan gratuito: el primer intento
        // tras un rato de inactividad puede tardar más que el timeout, y el
        // segundo va rápido. Decirlo evita leer "está caído" cuando está
        // despertando.
        'tardó demasiado en responder (si estuvo inactivo, puede estar '
            'arrancando — probá de nuevo en un minuto)',
      );
    }
    throw DownloadSourceException(
      DownloadSourceErrorKind.network,
      '${error.runtimeType}: $error',
    );
  }

  /// Mapea el código HTTP al tipo de error. El 415 del servidor es
  /// deliberadamente distinto del 502: significa "este vídeo no tiene pista
  /// AAC", que es definitivo, mientras que el 502 sí merece reintento.
  ///
  /// [retryAfterHeader] sólo se usa para el 429: es la cabecera `Retry-After`
  /// que el servidor calcula a partir de su propio limitador (nunca
  /// inventada acá, ver `DownloadSourceException.retryAfterSeconds`).
  void _checkStatus(int statusCode, String body, {String? retryAfterHeader}) {
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
        // NO notFound: un 400/422 lo decide la forma del cuerpo, no el
        // estado del vídeo. Colapsarlos hacía que un fallo de contrato entre
        // cliente y servidor se presentara como "ese vídeo ya no está
        // disponible" sobre un vídeo intacto.
        throw DownloadSourceException(DownloadSourceErrorKind.badRequest, detail);
      case 429:
        // El propio servidor se autolimitó (no YouTube): distinto de un 502
        // porque acá sí sabemos, con certeza, cuánto hay que esperar.
        //
        // Dos motivos posibles, distinguidos por `reason` en el cuerpo
        // (Fase 3 del plan de seguridad): el límite de PETICIONES de
        // `rate_limit.py` (sin `reason`, protección anti-abuso) o el cupo
        // diario de CANCIONES por cuenta (`reason: "daily_song_quota"`, un
        // límite de producto — "llegaste a tus 150 de hoy" merece su propio
        // mensaje, no el genérico de arriba).
        throw DownloadSourceException(
          _reasonFrom(body) == 'daily_song_quota'
              ? DownloadSourceErrorKind.dailyQuotaExceeded
              : DownloadSourceErrorKind.quotaExceeded,
          detail,
          retryAfterSeconds: int.tryParse((retryAfterHeader ?? '').trim()),
        );
      case 503:
        // El servidor distingue el muro anti-bot de YouTube de un 502
        // genérico (ver `AntiBotBlockError` en el servidor) precisamente para
        // que la cola le dé un trato distinto: minutos de espera real, no el
        // backoff corto de un 502 cualquiera.
        throw DownloadSourceException(DownloadSourceErrorKind.antiBotBlocked, detail);
      default:
        throw DownloadSourceException(
          DownloadSourceErrorKind.extraction,
          'El servidor respondió $statusCode: $detail',
        );
    }
  }

  /// El campo `reason` que sólo manda el 429 del cupo diario de canciones
  /// (ver `_daily_quota_response` en `server/app/main.py`) — el 429 genérico
  /// del limitador de peticiones no lo trae, así que `null` es el caso
  /// normal, no un error de parseo.
  String? _reasonFrom(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['reason'] != null) {
        return decoded['reason'].toString();
      }
    } catch (_) {
      // Cuerpo no-JSON: no puede traer `reason`, tratalo como ausente.
    }
    return null;
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
          .post(_uri(path), headers: await _headers(json: true), body: jsonEncode(body))
          .timeout(timeout);
      _checkStatus(response.statusCode, response.body, retryAfterHeader: response.headers['retry-after']);
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      _rethrowAsSourceError(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<RemoteTrack> resolve(String url) async {
    final json = await _postJson('/resolve', {'url': url}, _resolveTimeout);
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
          .get(_uri('/search', {'q': query, 'limit': '$limit'}), headers: await _headers())
          .timeout(_searchTimeout);
      _checkStatus(response.statusCode, response.body, retryAfterHeader: response.headers['retry-after']);
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
        ..headers.addAll(await _headers());
      final response = await client.send(request).timeout(_audioHeaderTimeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        _checkStatus(response.statusCode, body, retryAfterHeader: response.headers['retry-after']);
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
      //
      // 45 s y no 10: un servicio dormido en un plan gratuito tarda decenas
      // de segundos en levantarse, y con 10 s el diagnóstico contestaba
      // "apagado" justo cuando estaba arrancando — el diagnóstico existe para
      // resolver esa duda, no para añadirle otra.
      final health = await client.get(_uri('/health')).timeout(const Duration(seconds: 45));
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
            .get(_uri('/search', {'q': 'heardy', 'limit': '1'}), headers: await _headers())
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

  @override
  Future<UsageStatus> usage() async {
    if (_normalizedBase() == null) return UsageStatus.disabled;
    final client = _clientFactory();
    try {
      final response = await client
          .get(_uri('/usage'), headers: await _headers())
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return UsageStatus.disabled;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return UsageStatus.fromJson(json);
    } catch (_) {
      // No lanza a propósito (ver el doc de DownloadSource.usage): un fallo
      // acá se ve exactamente igual que "no hay cupo activo", y ninguno de
      // los dos amerita bloquear la pantalla de Añadir por esto.
      return UsageStatus.disabled;
    } finally {
      client.close();
    }
  }
}
