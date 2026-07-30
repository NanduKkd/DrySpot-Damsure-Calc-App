import 'package:flutter/material.dart';
import '../services/sync_service.dart';
import '../services/session_manager.dart';

class SyncProvider extends ChangeNotifier {
  final SyncService _syncService;
  bool _isSyncing = false;
  String? _lastSyncTime;
  String? _error;
  SessionSnapshot? _session;

  SyncProvider({required SyncService syncService}) : _syncService = syncService;

  bool get isSyncing => _isSyncing;
  String? get lastSyncTime => _lastSyncTime;
  String? get error => _error;

  void updateSession(SessionSnapshot? session) {
    if (_session?.generation == session?.generation) return;
    _session = session;
    _isSyncing = false;
    _lastSyncTime = null;
    _error = null;
    notifyListeners();
  }

  Future<void> sync() async {
    final session = _session;
    if (session == null) return;
    _isSyncing = true;
    _error = null;
    notifyListeners();

    try {
      await _syncService.sync(session);
      if (_session?.generation != session.generation) return;
      _lastSyncTime = DateTime.now().toIso8601String();
    } catch (e) {
      if (_session?.generation != session.generation) return;
      _error = e.toString();
    } finally {
      if (_session?.generation == session.generation) {
        _isSyncing = false;
        notifyListeners();
      }
    }
  }
}
