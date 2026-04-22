import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiService {
  static const _serverUrlKey = 'server_url';

  ApiService({String? serverUrl})
      : _serverUrl = normalizeServerUrl(
          serverUrl ?? AppConfig.defaultServerUrl,
        );

  String _serverUrl;
  String? _token;

  String get serverUrl => _serverUrl;
  String get baseUrl => '$_serverUrl/api';
  bool get _hasToken => _token?.isNotEmpty ?? false;

  void setToken(String token) {
    _token = token;
  }

  Future<void> loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final savedServerUrl = prefs.getString(_serverUrlKey);

    if (savedServerUrl == null || savedServerUrl.trim().isEmpty) {
      return;
    }

    _serverUrl = normalizeServerUrl(savedServerUrl);
  }

  Future<void> setServerUrl(String serverUrl) async {
    _serverUrl = normalizeServerUrl(serverUrl);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, _serverUrl);
  }

  static String normalizeServerUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Server URL cannot be empty.');
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException(
        'Enter a valid http:// or https:// server URL.',
      );
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const FormatException(
        'Only http:// and https:// server URLs are supported.',
      );
    }

    final segments =
        uri.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (segments.isNotEmpty && segments.last == 'api') {
      segments.removeLast();
    }

    final normalizedPath = segments.isEmpty ? '' : '/${segments.join('/')}';

    return uri
        .replace(
          path: normalizedPath,
          query: null,
          fragment: null,
        )
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_hasToken) 'Authorization': 'Bearer $_token',
      };

  Map<String, dynamic> _decodeObjectBody(
    String body, {
    required String fallbackMessage,
  }) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      throw ApiException(fallbackMessage);
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      throw ApiException(fallbackMessage);
    }

    throw ApiException(fallbackMessage);
  }

  String _extractErrorMessage(http.Response response, String fallbackMessage) {
    final trimmed = response.body.trim();
    if (trimmed.isEmpty) {
      return '$fallbackMessage (HTTP ${response.statusCode})';
    }

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final error = decoded['error'] ?? decoded['message'];
        if (error is String && error.trim().isNotEmpty) {
          return error.trim();
        }
      }
    } on FormatException {
      return trimmed;
    }

    return trimmed;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: _headers,
      body: jsonEncode({'email': email, 'password': password}),
    );

    if (response.statusCode == 200) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage: 'Login succeeded but the server response was invalid.',
      );
    } else {
      throw ApiException(_extractErrorMessage(response, 'Failed to login'));
    }
  }

  Future<Map<String, dynamic>> sync(Map<String, dynamic> data) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sync'),
      headers: _headers,
      body: jsonEncode(data),
    );

    if (response.statusCode == 200) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage: 'Sync succeeded but the server response was invalid.',
      );
    } else {
      throw ApiException(_extractErrorMessage(response, 'Failed to sync'));
    }
  }

  Future<Map<String, dynamic>> uploadWarranty(
      String filePath, Map<String, String> fields) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/warranty/upload'));
    request.headers.addAll({
      if (_hasToken) 'Authorization': 'Bearer $_token',
    });
    request.files.add(await http.MultipartFile.fromPath(
      'file',
      filePath,
      contentType: MediaType('application', 'pdf'),
    ));
    request.fields.addAll(fields);

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage:
            'Warranty upload succeeded but the server response was invalid.',
      );
    } else {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to upload warranty'),
      );
    }
  }

  Future<Map<String, dynamic>> uploadProposal(
      String filePath, Map<String, String> fields) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/proposal/upload'));
    request.headers.addAll({
      if (_hasToken) 'Authorization': 'Bearer $_token',
    });
    request.files.add(await http.MultipartFile.fromPath(
      'file',
      filePath,
      contentType: MediaType('application', 'pdf'),
    ));
    request.fields.addAll(fields);

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode == 201) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage:
            'Proposal upload succeeded but the server response was invalid.',
      );
    } else {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to upload proposal'),
      );
    }
  }

  Future<void> deleteProposal(String id) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/proposal/$id'),
      headers: _headers,
    );

    if (response.statusCode != 204) {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to delete proposal'),
      );
    }
  }
}
