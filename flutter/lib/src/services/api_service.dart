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

  Map<String, String> get authenticatedHeaders => {
        if (_hasToken) 'Authorization': 'Bearer $_token',
      };

  String resolveUrl(String pathOrUrl) {
    final uri = Uri.tryParse(pathOrUrl);
    if (uri != null && uri.hasScheme) return pathOrUrl;
    return '$_serverUrl${pathOrUrl.startsWith('/') ? '' : '/'}$pathOrUrl';
  }

  String? resolveProtectedClientPhotoUrl(String photoUrl) {
    if (photoUrl.startsWith('/api/photos/client/')) {
      return resolveUrl(photoUrl);
    }
    final uri = Uri.tryParse(photoUrl);
    final server = Uri.parse(_serverUrl);
    if (uri == null ||
        !uri.hasScheme ||
        uri.scheme != server.scheme ||
        uri.host != server.host ||
        uri.port != server.port ||
        !uri.path.startsWith('/api/photos/client/')) {
      return null;
    }
    return photoUrl;
  }

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
    String filePath,
    Map<String, String> fields, {
    String? idempotencyKey,
  }) async {
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/warranty/upload'));
    request.headers.addAll({
      if (_hasToken) 'Authorization': 'Bearer $_token',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
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

  Future<void> deleteWarranty({
    required String id,
    required String warrantyCardNumber,
    required int warrantyVersion,
    required String irreversibleConfirmation,
    required String idempotencyKey,
  }) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/warranty/$id'),
      headers: {
        ..._headers,
        'Idempotency-Key': idempotencyKey,
      },
      body: jsonEncode({
        'confirmed_warranty_id': id,
        'confirmed_warranty_card_number': warrantyCardNumber,
        'confirmed_warranty_version': warrantyVersion,
        'irreversible_confirmation': irreversibleConfirmation,
      }),
    );

    if (response.statusCode != 204) {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to delete warranty'),
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

  Future<String> uploadClientPhoto(String clientId, String filePath) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/photos/client/$clientId'),
    );
    request.headers.addAll(authenticatedHeaders);
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 201) {
      throw ApiException(
          _extractErrorMessage(response, 'Failed to upload photo'));
    }
    final payload = _decodeObjectBody(
      response.body,
      fallbackMessage:
          'Photo upload succeeded but the server response was invalid.',
    );
    final url = payload['url']?.toString();
    if (url == null || !url.startsWith('/api/photos/client/')) {
      throw const ApiException('Photo upload returned an invalid URL.');
    }
    return url;
  }

  Future<void> deleteClientPhoto(String photoUrl) async {
    final resolvedUrl = resolveProtectedClientPhotoUrl(photoUrl);
    if (resolvedUrl == null) {
      throw const ApiException('Photo URL is not on the configured server.');
    }
    final response = await http.delete(
      Uri.parse(resolvedUrl),
      headers: authenticatedHeaders,
    );
    if (response.statusCode != 204) {
      throw ApiException(
          _extractErrorMessage(response, 'Failed to delete photo'));
    }
  }
}
