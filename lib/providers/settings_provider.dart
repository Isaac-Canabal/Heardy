import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/official_server.dart';

enum AppThemePreset { navy, violet, rose }

class SettingsProvider with ChangeNotifier {
  static const _presetKey = 'theme_preset';
  static const _maxResultsKey = 'max_search_results';
  static const _serverUrlKey = 'download_server_url';
  static const _serverKeyKey = 'download_server_api_key';

  AppThemePreset _preset = AppThemePreset.navy;
  bool _loaded = false;
  int _maxSearchResults = 20;

  /// Por defecto, el servidor OFICIAL — modo automático (ver
  /// docs/arquitectura_servidor_hibrido.md, sección 4). Un usuario avanzado
  /// puede pisar esto desde Ajustes avanzados con `setDownloadServer`; nunca
  /// vuelve solo, hace falta `restoreOfficialServer` explícito.
  String _downloadServerUrl = OfficialServer.url;
  String _downloadServerApiKey = OfficialServer.apiKey;

  AppThemePreset get preset => _preset;
  bool get isLoaded => _loaded;
  int get maxSearchResults => _maxSearchResults;

  /// Dirección del microservidor de descargas (`server/` en este repo, ya
  /// sea el oficial o uno propio). Nunca queda vacía por defecto: apunta al
  /// servidor oficial hasta que el usuario elija explícitamente otro.
  String get downloadServerUrl => _downloadServerUrl;
  String get downloadServerApiKey => _downloadServerApiKey;
  bool get hasDownloadServer => _downloadServerUrl.trim().isNotEmpty;

  /// True mientras el servidor configurado sea el oficial — no sólo "está
  /// vacío", sino "coincide exactamente con `OfficialServer`". La pantalla
  /// de Ajustes lo usa para decidir cuándo mostrar "Restaurar servidor
  /// oficial": no tiene sentido ofrecerlo si ya se está usando.
  bool get isOfficialServer =>
      _downloadServerUrl.trim() == OfficialServer.url.trim() &&
      _downloadServerApiKey.trim() == OfficialServer.apiKey.trim();

  SettingsProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_presetKey);
    if (index != null && index >= 0 && index < AppThemePreset.values.length) {
      _preset = AppThemePreset.values[index];
    }
    _maxSearchResults = prefs.getInt(_maxResultsKey) ?? 20;
    _downloadServerUrl = prefs.getString(_serverUrlKey) ?? OfficialServer.url;
    _downloadServerApiKey =
        prefs.getString(_serverKeyKey) ?? OfficialServer.apiKey;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setDownloadServer({
    required String url,
    required String apiKey,
  }) async {
    _downloadServerUrl = url.trim();
    _downloadServerApiKey = apiKey.trim();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _downloadServerUrl);
    await prefs.setString(_serverKeyKey, _downloadServerApiKey);
  }

  /// Vuelve al servidor oficial. Un solo punto de entrada para el botón
  /// "Restaurar servidor oficial" de Ajustes avanzados — no duplica la
  /// lógica de guardado, reusa [setDownloadServer].
  Future<void> restoreOfficialServer() =>
      setDownloadServer(url: OfficialServer.url, apiKey: OfficialServer.apiKey);

  Future<void> setPreset(AppThemePreset preset) async {
    _preset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetKey, preset.index);
  }

  Future<void> setMaxSearchResults(int value) async {
    if (value >= 10 && value <= 100) {
      _maxSearchResults = value;
      notifyListeners();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_maxResultsKey, value);
    }
  }

  String presetLabel(AppThemePreset p) => switch (p) {
    AppThemePreset.navy => 'Azul nocturno',
    AppThemePreset.violet => 'Violeta neón',
    AppThemePreset.rose => 'Rosa eléctrico',
  };
}
