import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/updates/release_manifest.dart';
import 'package:app_client/src/updates/update_policy_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final trusted = DateTime.utc(2026, 7, 30, 10);

  Map<String, Object?> fixture(String name) => Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/release_manifest/$name.json').readAsStringSync(),
        ) as Map,
      );

  AvailableReleaseManifestResult available() => ReleaseManifestParser.parse(
        fixture('available_current'),
        trustedNowUtc: trusted,
      ) as AvailableReleaseManifestResult;

  DisabledReleaseManifestResult disabled() => ReleaseManifestParser.parse(
        fixture('disabled_v1'),
        trustedNowUtc: trusted,
      ) as DisabledReleaseManifestResult;

  test('atomically restores accepted available policy and its high-water',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = UpdatePolicyStore();
    final accepted = await store.accept(
      available(),
      trustedResponseAt: trusted,
    );

    final loaded = await store.load();
    expect(accepted, isNotNull);
    expect(loaded.kind, UpdatePolicyLoadKind.valid);
    expect(
      loaded.acceptedPolicy!.highWater.canonicalFingerprint,
      accepted!.highWater.canonicalFingerprint,
    );
    expect(
      (loaded.acceptedPolicy!.policy as AvailableReleaseManifestResult)
          .manifest
          .requiredUpdateReason,
      'Please update to continue using Damsure.',
    );
  });

  test('rejects corrupt or mixed persisted policy records', () async {
    SharedPreferences.setMockInitialValues({
      'app113.accepted_policy.v1': jsonEncode(<String, Object?>{
        'recordVersion': 1,
        'trustedResponseAt': '2026-07-30T10:00:00Z',
        'policy': fixture('available_current'),
        'highWater': <String, Object?>{
          'manifestRevision': 42,
          'canonicalFingerprint': 'changed',
          'latestVersionCode': 10400,
          'minimumSupportedVersionCode': 10300,
        },
      }),
    });

    expect(
        (await UpdatePolicyStore().load()).kind, UpdatePolicyLoadKind.corrupt);
  });

  test('never overwrites a corrupt atomic policy record during acceptance',
      () async {
    const corruptRecord = '{"recordVersion":1,"truncated":true}';
    SharedPreferences.setMockInitialValues({
      'app113.accepted_policy.v1': corruptRecord,
    });

    await expectLater(
      UpdatePolicyStore().accept(
        disabled(),
        trustedResponseAt: trusted.add(const Duration(hours: 1)),
      ),
      throwsA(isA<UpdatePolicyStoreException>()),
    );

    expect(
      (await SharedPreferences.getInstance())
          .getString('app113.accepted_policy.v1'),
      corruptRecord,
    );
  });

  test('newer disabled policy retains previous version maxima', () async {
    SharedPreferences.setMockInitialValues({});
    final store = UpdatePolicyStore();
    await store.accept(
      available(),
      trustedResponseAt: trusted,
    );
    final disabledPolicy = await store.accept(
      disabled(),
      trustedResponseAt: trusted.add(const Duration(minutes: 5)),
    );

    expect(disabledPolicy!.highWater.latestVersionCode, 10400);
    final reloaded = await store.load();
    expect(reloaded.kind, UpdatePolicyLoadKind.valid);
    expect(reloaded.acceptedPolicy!.highWater.latestVersionCode, 10400);
    expect(
      reloaded.acceptedPolicy!.highWater.minimumSupportedVersionCode,
      10300,
    );
  });

  test('rejects an accepted policy response whose trusted time moves backward',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = UpdatePolicyStore();
    final acceptedAt = trusted.add(const Duration(hours: 1));
    await store.accept(
      available(),
      trustedResponseAt: acceptedAt,
    );

    await expectLater(
      store.accept(
        disabled(),
        trustedResponseAt: trusted,
      ),
      throwsA(isA<UpdatePolicyStoreException>()),
    );

    final reloaded = await store.load();
    expect(reloaded.kind, UpdatePolicyLoadKind.valid);
    expect(reloaded.acceptedPolicy!.trustedResponseAt, acceptedAt);
    expect(reloaded.acceptedPolicy!.highWater.manifestRevision, 42);
  });

  test('optional dismissal uses the supplied trusted response time', () async {
    SharedPreferences.setMockInitialValues({});
    final store = UpdatePolicyStore();
    await store.dismissOptional(10400, trusted);
    final dismissal = await store.loadDismissal();
    expect(dismissal!.targetVersionCode, 10400);
    expect(dismissal.trustedDismissedAt, trusted);
  });
}
