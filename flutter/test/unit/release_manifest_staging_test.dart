import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/updates/release_manifest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('staging flavor binds only its compile-time release origin', () {
    const origin = 'https://staging.example.test';
    expect(releaseManifestEndpoint, '$origin/releases/manifest.json');
    final payload = Map<String, Object?>.from(
      jsonDecode(
        File('test/fixtures/release_manifest/available_current.json')
            .readAsStringSync(),
      ) as Map,
    )..['artifactUrl'] = '$origin/releases/damsure-10400.apk';
    final result = ReleaseManifestParser.parse(
      payload,
      trustedNowUtc: DateTime.utc(2026, 7, 30, 10),
    );
    expect(result, isA<AvailableReleaseManifestResult>());
    final highWater = ReleaseManifestHighWaterMark.fromAcceptedPolicy(
      result as AvailableReleaseManifestResult,
    );
    final disabled = Map<String, Object?>.from(
      jsonDecode(
        File('test/fixtures/release_manifest/disabled_v1.json')
            .readAsStringSync(),
      ) as Map,
    );
    final disabledResult = ReleaseManifestParser.parse(
      disabled,
      trustedNowUtc: DateTime.utc(2026, 7, 30, 10),
    ) as DisabledReleaseManifestResult;
    expect(
      validateManifestHighWater(disabledResult, previous: highWater).isAccepted,
      isTrue,
    );
  });
}
