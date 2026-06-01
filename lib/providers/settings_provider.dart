import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemePreset { navy, violet, rose }

class SettingsProvider with ChangeNotifier {
  static const _presetKey = 'theme_preset';

  AppThemePreset _preset = AppThemePreset.navy;
  bool _loaded = false;

  AppThemePreset get preset => _preset;
  bool get isLoaded => _loaded;

  SettingsProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_presetKey);
    if (index != null && index >= 0 && index < AppThemePreset.values.length) {
      _preset = AppThemePreset.values[index];
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setPreset(AppThemePreset preset) async {
    _preset = preset;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_presetKey, preset.index);
  }

  String presetLabel(AppThemePreset p) => switch (p) {
        AppThemePreset.navy => 'Azul nocturno',
        AppThemePreset.violet => 'Violeta neón',
        AppThemePreset.rose => 'Rosa eléctrico',
      };
}
