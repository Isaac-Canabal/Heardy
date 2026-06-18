import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemePreset { navy, violet, rose }

class SettingsProvider with ChangeNotifier {
  static const _presetKey = 'theme_preset';
  static const _maxResultsKey = 'max_search_results';

  AppThemePreset _preset = AppThemePreset.navy;
  bool _loaded = false;
  int _maxSearchResults = 20;

  AppThemePreset get preset => _preset;
  bool get isLoaded => _loaded;
  int get maxSearchResults => _maxSearchResults;

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
    _loaded = true;
    notifyListeners();
  }

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
