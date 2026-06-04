import 'package:flutter/foundation.dart';

class ErrorProvider with ChangeNotifier {
  String? _lastError;
  DateTime? _errorTime;
  final List<ErrorEntry> _errorHistory = [];

  String? get lastError => _lastError;
  DateTime? get errorTime => _errorTime;
  List<ErrorEntry> get errorHistory => List.unmodifiable(_errorHistory);
  bool get hasError => _lastError != null;

  void reportError(String error, {String? source}) {
    _lastError = error;
    _errorTime = DateTime.now();
    
    final entry = ErrorEntry(
      message: error,
      source: source ?? 'Unknown',
      time: _errorTime!,
    );
    
    _errorHistory.insert(0, entry);
    if (_errorHistory.length > 50) {
      _errorHistory.removeLast();
    }
    
    notifyListeners();
  }

  void clearError() {
    _lastError = null;
    _errorTime = null;
    notifyListeners();
  }

  void clearHistory() {
    _errorHistory.clear();
    _lastError = null;
    _errorTime = null;
    notifyListeners();
  }
}

class ErrorEntry {
  final String message;
  final String source;
  final DateTime time;

  ErrorEntry({
    required this.message,
    required this.source,
    required this.time,
  });
}
