import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/updates/update_state.dart';
import 'package:app_client/src/updates/update_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final body = utf8.encode(
    File('test/fixtures/release_manifest/available_current.json')
        .readAsStringSync(),
  );
  Map<String, List<String>> headers({String? date}) => <String, List<String>>{
        'content-type': const ['application/json; charset=utf-8'],
        'cache-control': const ['no-store, max-age=0'],
        'date': [date ?? 'Thu, 30 Jul 2026 10:00:00 GMT'],
      };

  List<int> validJsonBodyOfLength(int length) {
    const prefix = '{"payload":"';
    const suffix = '"}';
    final padding =
        length - utf8.encode(prefix).length - utf8.encode(suffix).length;
    assert(padding >= 0);
    return utf8
        .encode('$prefix${List<String>.filled(padding, 'a').join()}$suffix');
  }

  test('accepts only a no-store JSON response with a trusted Date', () {
    final result = ReleaseManifestTransportValidator.validate(
      statusCode: HttpStatus.ok,
      redirected: false,
      headers: headers(),
      body: body,
    );
    expect(result.trustedResponseAt, DateTime.utc(2026, 7, 30, 10));
  });

  test('rejects redirects, missing Date, bad cache policy, and bad media type',
      () {
    final cases = <({bool redirected, Map<String, List<String>> headers})>[
      (redirected: true, headers: headers()),
      (redirected: false, headers: headers(date: 'not a date')),
      (
        redirected: false,
        headers: <String, List<String>>{
          ...headers(),
          'cache-control': const ['max-age=0'],
        },
      ),
      (
        redirected: false,
        headers: <String, List<String>>{
          ...headers(),
          'content-type': const ['text/html'],
        },
      ),
    ];
    for (final entry in cases) {
      expect(
        () => ReleaseManifestTransportValidator.validate(
          statusCode: HttpStatus.ok,
          redirected: entry.redirected,
          headers: entry.headers,
          body: body,
        ),
        throwsA(
          isA<UpdateTransportException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.transport,
          ),
        ),
      );
    }
  });

  test('allows a 32 KiB manifest body and rejects every larger body', () {
    const maximumBytes = 32 * 1024;
    final atLimit = validJsonBodyOfLength(maximumBytes);
    expect(atLimit.length, maximumBytes);
    expect(
      ReleaseManifestTransportValidator.validate(
        statusCode: HttpStatus.ok,
        redirected: false,
        headers: headers(),
        body: atLimit,
      ).document,
      isA<Map>(),
    );

    for (final length in <int>[maximumBytes + 1, 40 * 1024]) {
      expect(
        () => ReleaseManifestTransportValidator.validate(
          statusCode: HttpStatus.ok,
          redirected: false,
          headers: headers(),
          body: validJsonBodyOfLength(length),
        ),
        throwsA(
          isA<UpdateTransportException>().having(
            (error) => error.kind,
            'kind',
            UpdateFailureKind.transport,
          ),
        ),
        reason: '$length-byte manifest must be rejected',
      );
    }
  });
}
