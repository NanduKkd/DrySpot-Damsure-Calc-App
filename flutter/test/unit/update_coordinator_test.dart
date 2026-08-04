import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/updates/android_update_bridge.dart';
import 'package:app_client/src/updates/release_manifest.dart';
import 'package:app_client/src/updates/update_coordinator.dart';
import 'package:app_client/src/updates/update_policy_store.dart';
import 'package:app_client/src/updates/update_state.dart';
import 'package:app_client/src/updates/update_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements UpdatePlatformBridge {
  const _Platform(this.versionCode);
  final int versionCode;

  @override
  Future<int> availableCacheBytes() async => 1024 * 1024 * 1024;
  @override
  Future<bool> canRequestPackageInstalls() async => true;
  @override
  Future<InstalledAndroidPackage> installedPackage() async =>
      InstalledAndroidPackage(versionCode: versionCode, versionName: '1.0.0');
  @override
  Future<AndroidUpdateResult> launchInstaller(
    File file,
    AvailableReleaseManifest manifest,
  ) async =>
      const AndroidUpdateResult.success();
  @override
  Future<void> openUnknownSourcesSettings() async {}
  @override
  Future<AndroidUpdateResult> verifyArtifact(
    File file,
    AvailableReleaseManifest manifest,
  ) async =>
      const AndroidUpdateResult.success();
}

class _Transport implements ReleaseManifestTransport {
  _Transport(this.response, {this.error});
  final TrustedManifestResponse? response;
  final UpdateFailureKind? error;
  int calls = 0;

  @override
  Future<TrustedManifestResponse> fetch() async {
    calls++;
    if (error != null) throw UpdateTransportException(error!);
    return response!;
  }
}

void main() {
  final trusted = DateTime.utc(2026, 7, 30, 10);

  Map<String, Object?> fixture(String name) => Map<String, Object?>.from(
        jsonDecode(
          File('test/fixtures/release_manifest/$name.json').readAsStringSync(),
        ) as Map,
      );

  TrustedManifestResponse availableResponse() => TrustedManifestResponse(
        document: fixture('available_current'),
        trustedResponseAt: trusted,
      );

  TrustedManifestResponse disabledResponse(DateTime trustedResponseAt) =>
      TrustedManifestResponse(
        document: fixture('disabled_v1'),
        trustedResponseAt: trustedResponseAt,
      );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('persists a required policy before it can be presented', () async {
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10299),
      transport: _Transport(availableResponse()),
    );

    await coordinator.initialize();

    expect(coordinator.state.policyStatus, UpdatePolicyStatus.required);
    expect(coordinator.state.blocksNormalFlow, isTrue);
    final stored = await UpdatePolicyStore().load();
    expect(stored.kind, UpdatePolicyLoadKind.valid);
    expect(stored.acceptedPolicy!.highWater.manifestRevision, 42);
  });

  test('cached required policy remains blocking through offline restart',
      () async {
    final store = UpdatePolicyStore();
    final parsed = ReleaseManifestParser.parse(
      fixture('available_current'),
      trustedNowUtc: trusted,
    ) as AvailableReleaseManifestResult;
    await store.accept(
      parsed,
      trustedResponseAt: trusted,
    );
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10299),
      transport: _Transport(null, error: UpdateFailureKind.network),
    );

    await coordinator.initialize();

    expect(coordinator.state.policyStatus, UpdatePolicyStatus.required);
    expect(coordinator.state.failure, UpdateFailureKind.network);
    expect(coordinator.state.blocksNormalFlow, isTrue);
  });

  test(
      'a corrupt policy record stays blocking and cannot be replaced by strict disabled metadata',
      () async {
    const corruptRecord = '{"recordVersion":1,"truncated":true}';
    SharedPreferences.setMockInitialValues({
      'app113.accepted_policy.v1': corruptRecord,
    });
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10299),
      transport:
          _Transport(disabledResponse(trusted.add(const Duration(hours: 1)))),
    );

    await coordinator.initialize();

    expect(coordinator.state.policyStatus, UpdatePolicyStatus.storageFailure);
    expect(coordinator.state.failure, UpdateFailureKind.storage);
    expect(coordinator.state.blocksNormalFlow, isTrue);
    expect(
      (await SharedPreferences.getInstance())
          .getString('app113.accepted_policy.v1'),
      corruptRecord,
      reason: 'no unprovable network recovery may overwrite unknown high-water',
    );
    expect(
        (await UpdatePolicyStore().load()).kind, UpdatePolicyLoadKind.corrupt);
  });

  test('an older trusted Date cannot change accepted policy or dismissal time',
      () async {
    final acceptedAt = trusted.add(const Duration(hours: 1));
    final store = UpdatePolicyStore();
    final accepted = await store.accept(
      ReleaseManifestParser.parse(
        fixture('available_current'),
        trustedNowUtc: acceptedAt,
      ) as AvailableReleaseManifestResult,
      trustedResponseAt: acceptedAt,
    );
    await store.dismissOptional(
      (accepted!.policy as AvailableReleaseManifestResult)
          .manifest
          .latestVersionCode,
      acceptedAt,
    );
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10350),
      transport: _Transport(availableResponse()),
    );

    await coordinator.initialize();

    expect(coordinator.state.policyStatus, UpdatePolicyStatus.optional);
    expect(coordinator.state.failure, UpdateFailureKind.rollback);
    expect(coordinator.state.trustedResponseAt, acceptedAt);
    expect(coordinator.state.showOptionalPrompt, isFalse);
    final reloaded = await store.load();
    expect(reloaded.acceptedPolicy!.trustedResponseAt, acceptedAt);
  });

  test(
      'optional dismissal is retained offline and overridden after 24 trusted hours',
      () async {
    final transport = _Transport(availableResponse());
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10350),
      transport: transport,
    );
    await coordinator.initialize();
    expect(coordinator.state.policyStatus, UpdatePolicyStatus.optional);
    expect(coordinator.state.showOptionalPrompt, isTrue);

    await coordinator.dismissOptional();
    expect(coordinator.state.showOptionalPrompt, isFalse);

    final offline = UpdateCoordinator(
      platform: const _Platform(10350),
      transport: _Transport(null, error: UpdateFailureKind.network),
    );
    await offline.initialize();
    expect(offline.state.policyStatus, UpdatePolicyStatus.optional);
    expect(offline.state.showOptionalPrompt, isFalse);

    final later = UpdateCoordinator(
      platform: const _Platform(10350),
      transport: _Transport(
        TrustedManifestResponse(
          document: fixture('available_current'),
          trustedResponseAt: trusted.add(const Duration(hours: 24)),
        ),
      ),
    );
    await later.initialize();
    expect(later.state.showOptionalPrompt, isTrue);
  });

  test('repeated checks are single-flight', () async {
    final transport = _Transport(availableResponse());
    final coordinator = UpdateCoordinator(
      platform: const _Platform(10400),
      transport: transport,
    );
    await Future.wait([coordinator.initialize(), coordinator.initialize()]);
    await Future.wait(
        [coordinator.checkForUpdates(), coordinator.checkForUpdates()]);
    expect(transport.calls, 2,
        reason: 'one startup check and one joined retry');
  });
}
