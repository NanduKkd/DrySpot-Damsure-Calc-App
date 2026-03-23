import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/warranty.dart';

class ApiService {
  final String baseUrl = 'http://localhost:3000/api';
  String? _token;

  void setToken(String token) {
    _token = token;
  }

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Failed to login');
    }
  }

  Future<Map<String, dynamic>> sync(Map<String, dynamic> data) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sync'),
      headers: _headers,
      body: jsonEncode(data),
    );

    if (response.statusCode == 200) {
      return jsonDecode(response.body);
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Failed to sync');
    }
  }

  Future<Warranty> uploadWarranty(Map<String, dynamic> data) async {
    // In a real app, this would be a multipart request
    final response = await http.post(
      Uri.parse('$baseUrl/warranty/upload'),
      headers: _headers,
      body: jsonEncode(data),
    );

    if (response.statusCode == 201) {
      return Warranty.fromJson(jsonDecode(response.body));
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Failed to upload warranty');
    }
  }

  Future<List<Warranty>> getWarranties(String clientId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/warranty/client/$clientId'),
      headers: _headers,
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => Warranty.fromJson(json)).toList();
    } else {
      throw Exception(jsonDecode(response.body)['error'] ?? 'Failed to get warranties');
    }
  }
}
