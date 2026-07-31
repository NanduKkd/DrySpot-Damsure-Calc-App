import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/app.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/providers/sync_provider.dart';
import 'package:app_client/src/screens/update/update_gate_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/updates/android_update_bridge.dart';
import 'package:app_client/src/updates/release_manifest.dart';
import 'package:app_client/src/updates/update_coordinator.dart';
import 'package:app_client/src/updates/update_policy_store.dart';
import 'package:app_client/src/updates/update_state.dart';
import 'package:app_client/src/updates/update_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements UpdatePlatformBridge {
  @override
  Future<int> availableCacheBytes() async => 1024 * 1024 * 1024;
  @override
  Future<bool> canRequestPackageInstalls() async => true;
  @override
  Future<InstalledAndroidPackage> installedPackage() async =>
      const InstalledAndroidPackage(versionCode: 10299, versionName: '1.0.0');
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

class _OfflineTransport implements ReleaseManifestTransport {
  @override
  Future<TrustedManifestResponse> fetch() =>
      Future<TrustedManifestResponse>.error(
        const UpdateTransportException(UpdateFailureKind.network),
      );
}

void main() {
  testWidgets(
      'required updater exists before auth/client providers are constructed',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final trusted = DateTime.utc(2026, 7, 30, 10);
    final payload = Map<String, Object?>.from(
      jsonDecode(
        File('test/fixtures/release_manifest/available_current.json')
            .readAsStringSync(),
      ) as Map,
    );
    final parsed = ReleaseManifestParser.parse(
      payload,
      trustedNowUtc: trusted,
    ) as AvailableReleaseManifestResult;
    await UpdatePolicyStore().accept(
      parsed,
      trustedResponseAt: trusted,
      previous: null,
    );
    final coordinator = UpdateCoordinator(
      platform: _Platform(),
      transport: _OfflineTransport(),
    );

    await tester.pumpWidget(
      App(
        apiService: ApiService(serverUrl: 'https://damsure.nandakrishnan.in'),
        updateCoordinator: coordinator,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(UpdateGateScreen), findsOneWidget);
    final gateContext = tester.element(find.byType(UpdateGateScreen));
    expect(
      () => gateContext.read<AuthProvider>(),
      throwsA(isA<ProviderNotFoundException>()),
    );
    expect(
      () => gateContext.read<ClientProvider>(),
      throwsA(isA<ProviderNotFoundException>()),
    );
    expect(
      () => gateContext.read<SettingsProvider>(),
      throwsA(isA<ProviderNotFoundException>()),
    );
    expect(
      () => gateContext.read<SyncProvider>(),
      throwsA(isA<ProviderNotFoundException>()),
    );
  });
}
