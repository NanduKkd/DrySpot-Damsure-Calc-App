import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/session_manager.dart';

class AuthProvider extends ChangeNotifier {
  static const minimumSplashDuration = Duration(seconds: 3);

  final ApiService apiService;
  final SessionManager _sessionManager;
  String? _token;
  String? _userName;
  String? _franchiseeId;
  String? _franchiseeName;
  bool _isRestoringSession = true;

  AuthProvider({required this.apiService, SessionManager? sessionManager})
      : _sessionManager = sessionManager ?? SessionManager();

  bool get isAuthenticated => _token?.isNotEmpty ?? false;
  bool get isRestoringSession => _isRestoringSession;
  String? get userName => _userName;
  String? get franchiseeId => _franchiseeId;
  String? get franchiseeName => _franchiseeName;

  Future<void> login(String email, String password) async {
    if (isAuthenticated) {
      throw StateError('Sign out before signing in with another account.');
    }
    final loginGeneration = _sessionManager.generation;
    final response = await apiService.login(email, password);
    if (_sessionManager.generation != loginGeneration || isAuthenticated) {
      throw const StaleSessionException();
    }
    final token = response['token']?.toString().trim();
    final user = response['user'];
    final franchiseeId =
        user is Map ? user['franchisee_id']?.toString().trim() : null;
    if (token == null ||
        token.isEmpty ||
        franchiseeId == null ||
        franchiseeId.isEmpty) {
      throw const FormatException('Login response did not include a session.');
    }
    final userName = user['name']?.toString();
    final franchiseeName = user['franchisee_name']?.toString();
    final snapshot = _sessionManager.activate(
      token: token,
      userName: userName,
      franchiseeId: franchiseeId,
      franchiseeName: franchiseeName,
    );
    _token = snapshot.token;
    _userName = snapshot.userName;
    _franchiseeId = snapshot.franchiseeId;
    _franchiseeName = snapshot.franchiseeName;
    _isRestoringSession = false;

    apiService.setToken(snapshot.token);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', snapshot.token);
    if (snapshot.userName != null) {
      await prefs.setString('user_name', snapshot.userName!);
    } else {
      await prefs.remove('user_name');
    }
    await prefs.setString('franchisee_id', snapshot.franchiseeId);
    if (_franchiseeName != null) {
      await prefs.setString('franchisee_name', _franchiseeName!);
    }
    // APP-111 owns the tenant cursor in SQLite.  A device-wide legacy cursor
    // has no safe owner and must never be carried into this session.
    await prefs.remove('last_sync_time');

    notifyListeners();
  }

  Future<void> tryAutoLogin() async {
    final restoreStartedAt = DateTime.now();
    _isRestoringSession = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      // A global cursor cannot safely be attributed after a restart, even if
      // the credential preference itself is malformed or absent.
      await prefs.remove('last_sync_time');
      if (prefs.containsKey('token')) {
        _token = prefs.getString('token');
        _userName = prefs.getString('user_name');
        _franchiseeId = prefs.getString('franchisee_id');
        _franchiseeName = prefs.getString('franchisee_name');

        if ((_token?.isNotEmpty ?? false) &&
            (_franchiseeId?.trim().isNotEmpty ?? false)) {
          final snapshot = _sessionManager.activate(
            token: _token!,
            userName: _userName,
            franchiseeId: _franchiseeId!,
            franchiseeName: _franchiseeName,
          );
          apiService.setToken(snapshot.token);
        } else {
          _token = null;
          _userName = null;
          _franchiseeId = null;
          _franchiseeName = null;
          _sessionManager.invalidate();
          apiService.setToken('');
        }
      }
    } catch (_) {
      _token = null;
      _userName = null;
      _franchiseeId = null;
      _franchiseeName = null;
      _sessionManager.invalidate();
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
    // This must happen before awaiting preferences so an in-flight request
    // loses the right to write as soon as the user confirms sign-out.
    _sessionManager.invalidate();
    _token = null;
    _userName = null;
    _franchiseeId = null;
    _franchiseeName = null;
    _isRestoringSession = false;
    apiService.setToken('');
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('user_name');
    await prefs.remove('franchisee_id');
    await prefs.remove('franchisee_name');
    await prefs.remove('last_sync_time');
  }
}

extension AuthProviderSessionAccess on AuthProvider {
  SessionSnapshot? get sessionSnapshot => _sessionManager.current;
}
