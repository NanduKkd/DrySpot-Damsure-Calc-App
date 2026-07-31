import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'release_manifest.dart';
import 'update_state.dart';

class UpdateTransportException implements Exception {
  const UpdateTransportException(this.kind);

  final UpdateFailureKind kind;
}

class TrustedManifestResponse {
  const TrustedManifestResponse({
    required this.document,
    required this.trustedResponseAt,
  });

  final Object? document;
  final DateTime trustedResponseAt;
}

abstract class ReleaseManifestTransport {
  Future<TrustedManifestResponse> fetch();
}

/// Performs the policy request without using [ApiService], credentials,
/// cookies, redirects, or caller-provided URLs. HTTPS authentication makes the
/// response Date the only time source supplied to APP-104's parser.
class NetworkReleaseManifestTransport implements ReleaseManifestTransport {
  NetworkReleaseManifestTransport({
    HttpClient Function()? clientFactory,
    this.connectionTimeout = const Duration(seconds: 10),
    this.bodyTimeout = const Duration(seconds: 15),
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static const _maximumManifestBytes = 64 * 1024;
  final HttpClient Function() _clientFactory;
  final Duration connectionTimeout;
  final Duration bodyTimeout;

  @override
  Future<TrustedManifestResponse> fetch() async {
    final endpoint = Uri.parse(releaseManifestEndpoint);
    if (!_isExactManifestEndpoint(endpoint)) {
      throw const UpdateTransportException(UpdateFailureKind.transport);
    }
    final client = _clientFactory()
      ..connectionTimeout = connectionTimeout
      ..autoUncompress = false;
    try {
      final request = await client.getUrl(endpoint).timeout(connectionTimeout);
      request
        ..followRedirects = false
        ..maxRedirects = 0
        ..persistentConnection = false;
      request.headers
        ..removeAll(HttpHeaders.authorizationHeader)
        ..removeAll(HttpHeaders.cookieHeader)
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(bodyTimeout);
      final headers = <String, List<String>>{
        'content-type':
            response.headers[HttpHeaders.contentTypeHeader] ?? const <String>[],
        'cache-control': response.headers[HttpHeaders.cacheControlHeader] ??
            const <String>[],
        'date': response.headers[HttpHeaders.dateHeader] ?? const <String>[],
      };
      final declaredLength =
          response.contentLength < 0 ? null : response.contentLength;
      if (declaredLength != null && declaredLength > _maximumManifestBytes) {
        throw const UpdateTransportException(UpdateFailureKind.transport);
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(bodyTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maximumManifestBytes) {
          throw const UpdateTransportException(UpdateFailureKind.transport);
        }
      }
      return ReleaseManifestTransportValidator.validate(
        statusCode: response.statusCode,
        redirected: response.redirects.isNotEmpty,
        headers: headers,
        body: bytes,
      );
    } on TimeoutException {
      throw const UpdateTransportException(UpdateFailureKind.timeout);
    } on UpdateTransportException {
      rethrow;
    } on Object {
      throw const UpdateTransportException(UpdateFailureKind.network);
    } finally {
      client.close(force: true);
    }
  }
}

/// Pure response checks make the transport boundary testable without a live
/// endpoint. No rejected body is returned to the UI or policy store.
class ReleaseManifestTransportValidator {
  const ReleaseManifestTransportValidator._();

  static TrustedManifestResponse validate({
    required int statusCode,
    required bool redirected,
    required Map<String, List<String>> headers,
    required List<int> body,
  }) {
    final normalizedHeaders = <String, List<String>>{
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final contentType = _singleHeader(normalizedHeaders, 'content-type');
    final cacheControl = normalizedHeaders['cache-control'] ?? const <String>[];
    final date = _singleHeader(normalizedHeaders, 'date');
    if (statusCode != HttpStatus.ok ||
        redirected ||
        !_isJsonUtf8(contentType) ||
        !_isNoStore(cacheControl) ||
        date == null ||
        body.length > NetworkReleaseManifestTransport._maximumManifestBytes) {
      throw const UpdateTransportException(UpdateFailureKind.transport);
    }
    final trustedTime = _parseHttpDate(date);
    if (trustedTime == null) {
      throw const UpdateTransportException(UpdateFailureKind.transport);
    }
    try {
      return TrustedManifestResponse(
        document: jsonDecode(utf8.decode(body, allowMalformed: false)),
        trustedResponseAt: trustedTime,
      );
    } on FormatException {
      throw const UpdateTransportException(UpdateFailureKind.malformed);
    }
  }

  static String? _singleHeader(Map<String, List<String>> headers, String name) {
    final values = headers[name] ?? const <String>[];
    return values.length == 1 ? values.single : null;
  }

  static bool _isJsonUtf8(String? header) {
    if (header == null) return false;
    final parts = header.split(';').map((part) => part.trim()).toList();
    if (parts.isEmpty || parts.first.toLowerCase() != 'application/json') {
      return false;
    }
    return parts.length == 1 ||
        (parts.length == 2 && parts[1].toLowerCase() == 'charset=utf-8');
  }

  static bool _isNoStore(List<String> values) {
    final directives = values
        .expand((value) => value.split(','))
        .map((value) => value.trim().toLowerCase())
        .toSet();
    return directives.contains('no-store') && directives.contains('max-age=0');
  }

  static DateTime? _parseHttpDate(String value) {
    try {
      return HttpDate.parse(value).toUtc();
    } on Object {
      return null;
    }
  }
}

bool _isExactManifestEndpoint(Uri endpoint) {
  final expected = Uri.parse(releaseManifestEndpoint);
  return endpoint == expected &&
      endpoint.scheme == 'https' &&
      endpoint.host.isNotEmpty &&
      !endpoint.hasPort &&
      endpoint.userInfo.isEmpty &&
      !endpoint.hasQuery &&
      !endpoint.hasFragment &&
      endpoint.path == '/releases/manifest.json';
}
