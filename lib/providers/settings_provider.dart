import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/official_server.dart';
import '../l10n/app_localizations.dart';

enum AppThemePreset { navy, violet, rose, green, orange, red, custom }

enum AppLanguage { es, en }

class SettingsProvider with ChangeNotifier {
  static const _presetKey = 'theme_preset';
  static const _maxResultsKey = 'max_search_results';
  static const _serverUrlKey = 'download_server_url';
  static const _serverKeyKey = 'download_server_api_key';
  static const _languageKey = 'app_language';
  static const _customPrimaryKey = 'custom_theme_primary';
  static const _customSecondaryKey = 'custom_theme_secondary';
  static const _customCombinedKey = 'custom_theme_combined';

  AppThemePreset _preset = AppThemePreset.navy;
  bool _loaded = false;
  int _maxSearchResults = 20;
  AppLanguage _language = AppLanguage.es;

  // Colores del modo "Personalizado" (AppThemePreset.custom). Persistidos
  // aparte del preset en sí, para que elegir otro preset y volver a
  // "Personalizado" no pierda lo elegido. Nunca se usan para dibujar nada
  // salvo cuando _preset == custom (ver AppTheme._p).
  Color _customPrimary = const Color(0xFF2563EB);
  Color _customSecondary = const Color(0xFF38BDF8);
  bool _customCombined = true;

  /// Por defecto, el servidor OFICIAL — modo automático (ver
  /// docs/arquitectura_servidor_hibrido.md, sección 4). Un usuario avanzado
  /// puede pisar esto desde Ajustes avanzados con `setDownloadServer`; nunca
  /// vuelve solo, hace falta `restoreOfficialServer` explícito.
  String _downloadServerUrl = OfficialServer.url;
  String _downloadServerApiKey = OfficialServer.apiKey;

  AppThemePreset get preset => _preset;
  bool get isLoaded => _loaded;
  int get maxSearchResults => _maxSearchResults;
  AppLanguage get language => _language;
  Locale get locale => Locale(_language.name);
  Color get customPrimary => _customPrimary;
  Color get customSecondary => _customSecondary;
  bool get customCombined => _customCombined;

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
    final langIndex = prefs.getInt(_languageKey);
    if (langIndex != null && langIndex >= 0 && langIndex < AppLanguage.values.length) {
      _language = AppLanguage.values[langIndex];
    }
    _downloadServerUrl = prefs.getString(_serverUrlKey) ?? OfficialServer.url;
    _downloadServerApiKey =
        prefs.getString(_serverKeyKey) ?? OfficialServer.apiKey;
    final customPrimaryArgb = prefs.getInt(_customPrimaryKey);
    if (customPrimaryArgb != null) _customPrimary = Color(customPrimaryArgb);
    final customSecondaryArgb = prefs.getInt(_customSecondaryKey);
    if (customSecondaryArgb != null) _customSecondary = Color(customSecondaryArgb);
    _customCombined = prefs.getBool(_customCombinedKey) ?? true;
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

  String presetLabel(BuildContext context, AppThemePreset p) {
    final l10n = AppLocalizations.of(context)!;
    return switch (p) {
      AppThemePreset.navy => l10n.themeNavy,
      AppThemePreset.violet => l10n.themeViolet,
      AppThemePreset.rose => l10n.themeRose,
      AppThemePreset.green => l10n.themeGreen,
      AppThemePreset.orange => l10n.themeOrange,
      AppThemePreset.red => l10n.themeRed,
      AppThemePreset.custom => l10n.themeCustom,
    };
  }

  /// Guarda los colores del modo "Personalizado" y lo activa como preset
  /// actual en un solo paso — separarlos obligaría a la UI a llamar a
  /// [setPreset] aparte y arriesgar un frame con colores nuevos pero preset
  /// viejo (o viceversa).
  Future<void> setCustomColors({
    required Color primary,
    required Color secondary,
    required bool combined,
  }) async {
    _customPrimary = primary;
    _customSecondary = secondary;
    _customCombined = combined;
    _preset = AppThemePreset.custom;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_customPrimaryKey, primary.toARGB32());
    await prefs.setInt(_customSecondaryKey, secondary.toARGB32());
    await prefs.setBool(_customCombinedKey, combined);
    await prefs.setInt(_presetKey, AppThemePreset.custom.index);
  }

  Future<void> setLanguage(AppLanguage language) async {
    _language = language;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_languageKey, language.index);
  }

  String languageLabel(AppLanguage l) => switch (l) {
    AppLanguage.es => 'Español',
    AppLanguage.en => 'English',
  };
}
