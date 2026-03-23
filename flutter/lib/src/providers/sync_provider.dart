import 'package:flutter/material.dart';
import '../services/sync_service.dart';

class SyncProvider extends ChangeNotifier {
  final SyncService _syncService;
  bool _isSyncing = false;
  String? _lastSyncTime;
  String? _error;

  SyncProvider({required SyncService syncService}) : _syncService = syncService;

  bool get isSyncing => _isSyncing;
  String? get lastSyncTime => _lastSyncTime;
  String? get error => _error;

  Future<void> sync() async {
    _isSyncing = true;
    _error = null;
    notifyListeners();

    try {
      await _syncService.sync();
      _lastSyncTime = DateTime.now().toIso8601String();
    } catch (e) {
      _error = e.toString();
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }
}
