import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiService apiService;
  String? _token;
  String? _userName;
  String? _franchiseeId;

  AuthProvider({required this.apiService});

  bool get isAuthenticated => _token != null;
  String? get userName => _userName;
  String? get franchiseeId => _franchiseeId;

  Future<void> login(String email, String password) async {
    final response = await apiService.login(email, password);
    _token = response['token'];
    _userName = response['user']['name'];
    _franchiseeId = response['user']['franchisee_id'];
    
    apiService.setToken(_token!);
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', _token!);
    await prefs.setString('user_name', _userName!);
    await prefs.setString('franchisee_id', _franchiseeId!);
    
    notifyListeners();
  }

  Future<void> tryAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey('token')) return;

    _token = prefs.getString('token');
    _userName = prefs.getString('user_name');
    _franchiseeId = prefs.getString('franchisee_id');

    if (_token != null) {
      apiService.setToken(_token!);
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _token = null;
    _userName = null;
    _franchiseeId = null;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    
    notifyListeners();
  }
}
