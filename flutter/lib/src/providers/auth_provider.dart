import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  static const minimumSplashDuration = Duration(seconds: 3);

  final ApiService apiService;
  String? _token;
  String? _userName;
  String? _franchiseeId;
  String? _franchiseeName;
  bool _isRestoringSession = true;

  AuthProvider({required this.apiService});

  bool get isAuthenticated => _token?.isNotEmpty ?? false;
  bool get isRestoringSession => _isRestoringSession;
  String? get userName => _userName;
  String? get franchiseeId => _franchiseeId;
  String? get franchiseeName => _franchiseeName;

  String _syncTimeKey(String? franchiseeId) {
    if (franchiseeId == null || franchiseeId.isEmpty) {
      return 'last_sync_time';
    }
    return 'last_sync_time_$franchiseeId';
  }

  Future<void> login(String email, String password) async {
    final previousFranchiseeId = _franchiseeId;
    final response = await apiService.login(email, password);
    _token = response['token'];
    _userName = response['user']['name'];
    _franchiseeId = response['user']['franchisee_id'];
    _franchiseeName = response['user']['franchisee_name'];
    _isRestoringSession = false;

    apiService.setToken(_token!);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', _token!);
    await prefs.setString('user_name', _userName!);
    await prefs.setString('franchisee_id', _franchiseeId!);
    if (_franchiseeName != null)
      await prefs.setString('franchisee_name', _franchiseeName!);
    await prefs.remove('last_sync_time');

    if (previousFranchiseeId != null &&
        previousFranchiseeId != _franchiseeId &&
        _franchiseeId != null) {
      await prefs.remove(_syncTimeKey(_franchiseeId));
    }

    notifyListeners();
  }

  Future<void> tryAutoLogin() async {
    final restoreStartedAt = DateTime.now();
    _isRestoringSession = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey('token')) {
        _token = prefs.getString('token');
        _userName = prefs.getString('user_name');
        _franchiseeId = prefs.getString('franchisee_id');
        _franchiseeName = prefs.getString('franchisee_name');

        if (_token?.isNotEmpty ?? false) {
          apiService.setToken(_token!);
        } else {
          _token = null;
          apiService.setToken('');
        }
      }
    } catch (_) {
      _token = null;
      _userName = null;
      _franchiseeId = null;
      _franchiseeName = null;
      apiService.setToken('');
    }

    final elapsed = DateTime.now().difference(restoreStartedAt);
    final remaining = minimumSplashDuration - elapsed;
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }

    _isRestoringSession = false;
    notifyListeners();
  }

  Future<void> logout() async {
    final activeFranchiseeId = _franchiseeId;
    _token = null;
    _userName = null;
    _franchiseeId = null;
    _franchiseeName = null;
    _isRestoringSession = false;
    apiService.setToken('');

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('user_name');
    await prefs.remove('franchisee_id');
    await prefs.remove('franchisee_name');
    await prefs.remove('last_sync_time');
    await prefs.remove(_syncTimeKey(activeFranchiseeId));

    notifyListeners();
  }
}
