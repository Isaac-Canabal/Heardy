import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'cloud_source.dart';

/// La única implementación real de [CloudSource]: HTTP contra el mismo
/// servidor de descargas (`server/`), con las rutas de la Etapa 16
/// (`/account`, `/friends*`, `/library`, `/history`, `/stats/*`,
/// `/presence`). Molde calcado de `ytdlp_server_source.dart`: timeout
/// explícito en cada llamada, `Authorization: Bearer` desde un closure.
class HeardyCloudSource implements CloudSource {
  static const _timeout = Duration(seconds: 20);
  static const _libraryTimeout = Duration(seconds: 60);

  final String Function() _baseUrlProvider;
  final Future<String?> Function() _authTokenProvider;
  final http.Client Function() _clientFactory;

  HeardyCloudSource({
    required String Function() baseUrl,
    required Future<String?> Function() authToken,
    http.Client Function()? clientFactory,
  })  : _baseUrlProvider = baseUrl,
        _authTokenProvider = authToken,
        _clientFactory = clientFactory ?? (() => http.Client());

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
      throw const CloudSourceException(CloudSourceErrorKind.badRequest, 'No hay servidor configurado');
    }
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers({bool json = false, String? ifNoneMatch}) async {
    final token = await _authTokenProvider();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (json) 'Content-Type': 'application/json',
      if (ifNoneMatch != null) 'If-None-Match': ifNoneMatch,
    };
  }

  Never _rethrow(Object error) {
    if (error is CloudSourceException) throw error;
    if (error is TimeoutException) {
      throw const CloudSourceException(CloudSourceErrorKind.network, 'El servidor tardó demasiado en responder');
    }
    if (error is SocketException || error is HttpException || error is HandshakeException) {
      throw CloudSourceException(CloudSourceErrorKind.network, error.toString());
    }
    throw CloudSourceException(CloudSourceErrorKind.network, error.toString());
  }

  String _detailFrom(String body) {
    if (body.isEmpty) return 'sin detalle';
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] != null) return decoded['detail'].toString();
    } catch (_) {
      // cuerpo no-JSON
    }
    return body.length > 300 ? '${body.substring(0, 300)}…' : body;
  }

  bool _isVersionConflict(String body) {
    try {
      final decoded = jsonDecode(body);
      final detail = decoded is Map ? decoded['detail'] : null;
      if (detail is Map && detail['reason'] == 'library_version_conflict') return true;
    } catch (_) {
      // no-JSON
    }
    return false;
  }

  Map<String, dynamic> _checkAndDecode(http.Response response) {
    final code = response.statusCode;
    if (code >= 200 && code < 300) {
      if (response.bodyBytes.isEmpty) return const {};
      return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    }
    final body = response.body;
    switch (code) {
      case 401:
      case 403:
        throw CloudSourceException(CloudSourceErrorKind.unauthorized, _detailFrom(body));
      case 404:
        throw CloudSourceException(CloudSourceErrorKind.notFound, _detailFrom(body));
      case 409:
        throw CloudSourceException(
          CloudSourceErrorKind.conflict,
          _detailFrom(body),
          isVersionConflict: _isVersionConflict(body),
        );
      case 428:
        throw CloudSourceException(CloudSourceErrorKind.needsUsername, _detailFrom(body));
      case 429:
        throw CloudSourceException(
          CloudSourceErrorKind.quotaExceeded,
          _detailFrom(body),
          retryAfterSeconds: int.tryParse((response.headers['retry-after'] ?? '').trim()),
        );
      case 400:
      case 413:
      case 422:
        throw CloudSourceException(CloudSourceErrorKind.badRequest, _detailFrom(body));
      default:
        throw CloudSourceException(CloudSourceErrorKind.network, 'El servidor respondió $code: ${_detailFrom(body)}');
    }
  }

  Future<Map<String, dynamic>> _get(String path, {Map<String, String>? query, String? ifNoneMatch}) async {
    final client = _clientFactory();
    try {
      final response = await client
          .get(_uri(path, query), headers: await _headers(ifNoneMatch: ifNoneMatch))
          .timeout(_timeout);
      if (response.statusCode == 304) return const {'_notModified': true};
      return _checkAndDecode(response);
    } catch (e) {
      _rethrow(e);
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    Duration? timeout,
  }) async {
    final client = _clientFactory();
    try {
      final request = http.Request(method, _uri(path))..headers.addAll(await _headers(json: true));
      if (body != null) request.body = jsonEncode(body);
      final streamed = await client.send(request).timeout(timeout ?? _timeout);
      final response = await http.Response.fromStream(streamed);
      return _checkAndDecode(response);
    } catch (e) {
      _rethrow(e);
    } finally {
      client.close();
    }
  }

  @override
  Future<CloudAccount> getAccount() async => CloudAccount.fromJson(await _get('/account'));

  @override
  Future<String> setUsername(String username) async {
    final json = await _send('PUT', '/account/username', {'username': username});
    return (json['username'] ?? username).toString();
  }

  @override
  Future<UserLookupResult> lookupUser(String username) async =>
      UserLookupResult.fromJson(await _get('/users/lookup', query: {'username': username}));

  @override
  Future<String> sendFriendRequest(String username) async {
    final json = await _send('POST', '/friends/requests', {'username': username});
    return (json['status'] ?? 'pending').toString();
  }

  @override
  Future<void> acceptFriendRequest(String username) async {
    await _send('POST', '/friends/requests/$username/accept', null);
  }

  @override
  Future<void> rejectOrCancelFriendRequest(String username) async {
    await _send('DELETE', '/friends/requests/$username', null);
  }

  @override
  Future<void> removeFriend(String username) async {
    await _send('DELETE', '/friends/$username', null);
  }

  @override
  Future<FriendsList> getFriends() async => FriendsList.fromJson(await _get('/friends'));

  @override
  Future<CloudLibraryOrNotModified> getLibrary({String? ifNoneMatchVersion}) async {
    final json = await _get('/library', ifNoneMatch: ifNoneMatchVersion);
    if (json['_notModified'] == true) return null;
    return CloudLibrary.fromJson(json);
  }

  @override
  Future<int> pushLibrary({
    required int baseVersion,
    String? contentHash,
    required List<Map<String, dynamic>> songs,
    required List<Map<String, dynamic>> playlists,
    required List<Map<String, dynamic>> playlistSongs,
  }) async {
    final json = await _send(
      'PUT',
      '/library',
      {
        'baseVersion': baseVersion,
        if (contentHash != null) 'contentHash': contentHash,
        'songs': songs,
        'playlists': playlists,
        'playlistSongs': playlistSongs,
      },
      timeout: _libraryTimeout,
    );
    return (json['version'] as num?)?.toInt() ?? baseVersion;
  }

  @override
  Future<HistoryPushResult> pushHistory(List<Map<String, dynamic>> rows, {int? utcOffsetMinutes}) async {
    final json = await _send(
      'POST',
      '/history',
      {
        'rows': rows,
        if (utcOffsetMinutes != null) 'utcOffsetMinutes': utcOffsetMinutes,
      },
      timeout: _libraryTimeout,
    );
    return HistoryPushResult.fromJson(json);
  }

  @override
  Future<Map<String, dynamic>> getStatsMe({required String period, int? utcOffsetMinutes}) async {
    return _get('/stats/me', query: {
      'period': period,
      if (utcOffsetMinutes != null) 'utcOffsetMinutes': '$utcOffsetMinutes',
    });
  }

  @override
  Future<Map<String, dynamic>> getStatsFriend(String username, {required String period}) async {
    return _get('/stats/$username', query: {'period': period});
  }

  @override
  Future<void> putPresence({required String songId, required int expiresInSeconds}) async {
    await _send('PUT', '/presence', {'songId': songId, 'expiresInSeconds': expiresInSeconds});
  }

  @override
  Future<void> clearPresence() async {
    await _send('DELETE', '/presence', null);
  }

  @override
  Future<bool> setShareNowPlaying(bool enabled) async {
    final json = await _send('PATCH', '/account/settings', {'shareNowPlaying': enabled});
    return json['shareNowPlaying'] == true;
  }

  @override
  Future<void> deleteAccountData() async {
    await _send('DELETE', '/account/data', null);
  }
}
