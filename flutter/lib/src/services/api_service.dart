import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'session_manager.dart';

class ApiException implements Exception {
  const ApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.endpointMissing = false,
  });

  final String message;
  final int? statusCode;
  final String? code;
  final bool endpointMissing;

  @override
  String toString() => message;
}

class ApiService {
  static const _serverUrlKey = 'server_url';
  static final _canonicalUploadedPhotoName = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    r'\.(jpg|png|webp)$',
  );

  ApiService({String? serverUrl})
      : _serverUrl =
            normalizeServerUrl(serverUrl ?? AppConfig.defaultServerUrl);

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
        .replace(path: normalizedPath, query: null, fragment: null)
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

  Map<String, String> authenticatedHeadersFor(SessionSnapshot? session) => {
        if (session != null)
          'Authorization': 'Bearer ${session.token}'
        else if (_hasToken)
          'Authorization': 'Bearer $_token',
      };

  Map<String, String> _headersFor(SessionSnapshot? session) => {
        'Content-Type': 'application/json',
        ...authenticatedHeadersFor(session),
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

  ApiException _exceptionFor(http.Response response, String fallbackMessage) {
    var message = _extractErrorMessage(response, fallbackMessage);
    String? code;
    var structuredResponse = false;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        structuredResponse = true;
        final rawError = decoded['error'];
        if (rawError is Map) {
          final nestedMessage = rawError['message'];
          if (nestedMessage is String && nestedMessage.trim().isNotEmpty) {
            message = nestedMessage.trim();
          }
          code = rawError['code']?.toString();
        } else {
          code = decoded['code']?.toString();
        }
      }
    } on FormatException {
      // The HTTP status remains sufficient to identify an absent old endpoint.
    }
    return ApiException(
      message,
      statusCode: response.statusCode,
      code: code,
      endpointMissing: response.statusCode == 404 && !structuredResponse,
    );
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

  Future<Map<String, dynamic>> sync(Map<String, dynamic> data) => _sync(data);

  Future<Map<String, dynamic>> syncForSession(
    Map<String, dynamic> data,
    SessionSnapshot session,
  ) =>
      _sync(data, session);

  Future<Map<String, dynamic>> _sync(
    Map<String, dynamic> data, [
    SessionSnapshot? session,
  ]) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sync'),
      headers: _headersFor(session),
      body: jsonEncode(data),
    );

    if (response.statusCode == 200) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage: 'Sync succeeded but the server response was invalid.',
      );
    } else {
      throw _exceptionFor(response, 'Failed to sync');
    }
  }

  Future<Map<String, dynamic>> syncV2(Map<String, dynamic> data) =>
      _syncV2(data);

  Future<Map<String, dynamic>> syncV2ForSession(
    Map<String, dynamic> data,
    SessionSnapshot session,
  ) =>
      _syncV2(data, session);

  Future<Map<String, dynamic>> _syncV2(
    Map<String, dynamic> data, [
    SessionSnapshot? session,
  ]) async {
    final response = await http.post(
      Uri.parse('$baseUrl/sync/v2'),
      headers: _headersFor(session),
      body: jsonEncode(data),
    );

    if (response.statusCode == 200) {
      return _decodeObjectBody(
        response.body,
        fallbackMessage:
            'Sync v2 succeeded but the server response was invalid.',
      );
    }
    throw _exceptionFor(response, 'Failed to sync');
  }

  Future<Map<String, dynamic>> uploadWarranty(
    String filePath,
    Map<String, String> fields, {
    String? idempotencyKey,
  }) =>
      _uploadWarranty(filePath, fields, idempotencyKey: idempotencyKey);

  Future<Map<String, dynamic>> uploadWarrantyForSession(
    String filePath,
    Map<String, String> fields,
    SessionSnapshot session, {
    String? idempotencyKey,
  }) =>
      _uploadWarranty(
        filePath,
        fields,
        idempotencyKey: idempotencyKey,
        session: session,
      );

  Future<Map<String, dynamic>> _uploadWarranty(
    String filePath,
    Map<String, String> fields, {
    String? idempotencyKey,
    SessionSnapshot? session,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/warranty/upload'),
    );
    request.headers.addAll({
      ...authenticatedHeadersFor(session),
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    });
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        filePath,
        contentType: MediaType('application', 'pdf'),
      ),
    );
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

  Future<Map<String, dynamic>> deleteWarranty({
    required String id,
    required String warrantyCardNumber,
    required int warrantyVersion,
    required String irreversibleConfirmation,
    required String idempotencyKey,
  }) =>
      _deleteWarranty(
        id: id,
        warrantyCardNumber: warrantyCardNumber,
        warrantyVersion: warrantyVersion,
        irreversibleConfirmation: irreversibleConfirmation,
        idempotencyKey: idempotencyKey,
      );

  Future<Map<String, dynamic>> deleteWarrantyForSession({
    required String id,
    required String warrantyCardNumber,
    required int warrantyVersion,
    required String irreversibleConfirmation,
    required String idempotencyKey,
    required SessionSnapshot session,
  }) =>
      _deleteWarranty(
        id: id,
        warrantyCardNumber: warrantyCardNumber,
        warrantyVersion: warrantyVersion,
        irreversibleConfirmation: irreversibleConfirmation,
        idempotencyKey: idempotencyKey,
        session: session,
      );

  Future<Map<String, dynamic>> _deleteWarranty({
    required String id,
    required String warrantyCardNumber,
    required int warrantyVersion,
    required String irreversibleConfirmation,
    required String idempotencyKey,
    SessionSnapshot? session,
  }) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/warranty/$id'),
      headers: {..._headersFor(session), 'Idempotency-Key': idempotencyKey},
      body: jsonEncode({
        'confirmed_warranty_id': id,
        'confirmed_warranty_card_number': warrantyCardNumber,
        'confirmed_warranty_version': warrantyVersion,
        'irreversible_confirmation': irreversibleConfirmation,
      }),
    );

    if (response.statusCode == 200) {
      final result = _decodeObjectBody(
        response.body,
        fallbackMessage:
            'Warranty deletion succeeded but the server response was invalid.',
      );
      if (result['status'] != 'deleted' || result['warranty_id'] != id) {
        throw const ApiException(
          'Warranty deletion returned an invalid result.',
        );
      }
      return result;
    }
    throw ApiException(
      _extractErrorMessage(response, 'Failed to delete warranty'),
    );
  }

  Future<Map<String, dynamic>> uploadProposal(
    String filePath,
    Map<String, String> fields,
  ) =>
      _uploadProposal(filePath, fields);

  Future<Map<String, dynamic>> uploadProposalForSession(
    String filePath,
    Map<String, String> fields,
    SessionSnapshot session,
  ) =>
      _uploadProposal(filePath, fields, session);

  Future<Map<String, dynamic>> _uploadProposal(
    String filePath,
    Map<String, String> fields, [
    SessionSnapshot? session,
  ]) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/proposal/upload'),
    );
    request.headers.addAll(authenticatedHeadersFor(session));
    request.files.add(
      await http.MultipartFile.fromPath(
        'file',
        filePath,
        contentType: MediaType('application', 'pdf'),
      ),
    );
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

  Future<void> deleteProposal(String id) => _deleteProposal(id);

  Future<void> deleteProposalForSession(
    String id,
    SessionSnapshot session,
  ) =>
      _deleteProposal(id, session);

  Future<void> _deleteProposal(String id, [SessionSnapshot? session]) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/proposal/$id'),
      headers: _headersFor(session),
    );

    if (response.statusCode != 204) {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to delete proposal'),
      );
    }
  }

  Future<String> uploadClientPhoto(String clientId, String filePath) =>
      _uploadClientPhoto(clientId, filePath);

  Future<String> uploadClientPhotoForSession(
    String clientId,
    String filePath,
    SessionSnapshot session,
  ) =>
      _uploadClientPhoto(clientId, filePath, session);

  Future<String> _uploadClientPhoto(
    String clientId,
    String filePath, [
    SessionSnapshot? session,
  ]) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/photos/client/$clientId'),
    );
    request.headers.addAll(authenticatedHeadersFor(session));
    request.files.add(await http.MultipartFile.fromPath('file', filePath));

    final response = await http.Response.fromStream(await request.send());
    if (response.statusCode != 201) {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to upload photo'),
      );
    }
    final payload = _decodeObjectBody(
      response.body,
      fallbackMessage:
          'Photo upload succeeded but the server response was invalid.',
    );
    final url = payload['url']?.toString();
    final expectedPrefix = '/api/photos/client/$clientId/';
    if (url == null ||
        !url.startsWith(expectedPrefix) ||
        !_canonicalUploadedPhotoName.hasMatch(
          url.substring(expectedPrefix.length),
        )) {
      throw const ApiException('Photo upload returned an invalid URL.');
    }
    return url;
  }

  Future<void> deleteClientPhoto(String photoUrl) =>
      _deleteClientPhoto(photoUrl);

  Future<void> deleteClientPhotoForSession(
    String photoUrl,
    SessionSnapshot session,
  ) =>
      _deleteClientPhoto(photoUrl, session);

  Future<void> _deleteClientPhoto(
    String photoUrl, [
    SessionSnapshot? session,
  ]) async {
    final resolvedUrl = resolveProtectedClientPhotoUrl(photoUrl);
    if (resolvedUrl == null) {
      throw const ApiException('Photo URL is not on the configured server.');
    }
    final response = await http.delete(
      Uri.parse(resolvedUrl),
      headers: authenticatedHeadersFor(session),
    );
    if (response.statusCode != 204) {
      throw ApiException(
        _extractErrorMessage(response, 'Failed to delete photo'),
      );
    }
  }
}
