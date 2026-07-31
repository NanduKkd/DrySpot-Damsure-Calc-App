import 'dart:convert';
import 'dart:io';

import 'package:app_client/src/app.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/providers/sync_provider.dart';
import 'package:app_client/src/screens/settings/settings_screen.dart';
import 'package:app_client/src/screens/splash_screen.dart';
import 'package:app_client/src/screens/update/update_gate_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/updates/android_update_bridge.dart';
import 'package:app_client/src/updates/release_manifest.dart';
import 'package:app_client/src/updates/update_coordinator.dart';
import 'package:app_client/src/updates/update_policy_store.dart';
import 'package:app_client/src/updates/update_state.dart';
import 'package:app_client/src/updates/update_transport.dart';
import 'package:flutter/material.dart';
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

class _ControllableCoordinator extends UpdateCoordinator {
  _ControllableCoordinator() : super(platform: _Platform());

  int manualChecks = 0;
  int optionalDismissals = 0;
  int installRequests = 0;

  UpdateViewState _controlledState = const UpdateViewState(
    policyStatus: UpdatePolicyStatus.disabled,
    isChecking: false,
  );

  @override
  UpdateViewState get state => _controlledState;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> reconcileInstalledVersionAfterResume() async {}

  AvailableReleaseManifest get _manifest => AvailableReleaseManifest(
        manifestRevision: 42,
        latestVersion: '1.4.0',
        latestVersionCode: 10400,
        minimumSupportedVersionCode: 10300,
        artifactUrl: Uri.parse(
          'https://damsure.nandakrishnan.in/releases/damsure-10400.apk',
        ),
        sha256: 'a' * 64,
        sizeBytes: 1024,
        publishedAt: DateTime.utc(2026, 7, 30, 10),
        releaseNotes: 'Required release.',
        requiredUpdateReason: 'Update to continue.',
      );

  @override
  Future<void> checkForUpdates({bool manual = false}) async {
    if (manual) manualChecks++;
    _controlledState = UpdateViewState(
      policyStatus: UpdatePolicyStatus.optional,
      manifest: _manifest,
      trustedResponseAt: DateTime.utc(2026, 7, 30, 10),
      showOptionalPrompt: true,
      isChecking: false,
    );
    notifyListeners();
  }

  @override
  Future<void> dismissOptional() async {
    optionalDismissals++;
    _controlledState = _controlledState.copyWith(showOptionalPrompt: false);
    notifyListeners();
  }

  @override
  Future<void> downloadAndInstall() async {
    installRequests++;
  }

  void requireUpdate() {
    _controlledState = UpdateViewState(
      policyStatus: UpdatePolicyStatus.required,
      manifest: _manifest,
      isChecking: false,
    );
    notifyListeners();
  }
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

  testWidgets(
      'pushed normal routes retain app providers and are removed by a live required gate',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final coordinator = _ControllableCoordinator();
    await tester.pumpWidget(
      App(
        apiService: ApiService(serverUrl: 'https://damsure.nandakrishnan.in'),
        updateCoordinator: coordinator,
      ),
    );
    await tester.pump();

    final normalContext = tester.element(find.byType(SplashScreen));
    Navigator.of(normalContext).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    await tester.pumpAndSettle();

    final settingsContext = tester.element(find.byType(SettingsScreen));
    expect(settingsContext.read<AuthProvider>(), isA<AuthProvider>());
    expect(settingsContext.read<ClientProvider>(), isA<ClientProvider>());
    expect(settingsContext.read<SettingsProvider>(), isA<SettingsProvider>());
    expect(settingsContext.read<SyncProvider>(), isA<SyncProvider>());

    // Let the deliberately delayed auth restore finish while the normal route
    // is still permitted, so the test does not leave its timer pending.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();

    coordinator.requireUpdate();
    await tester.pumpAndSettle();

    expect(find.byType(UpdateGateScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('manual Settings checks show optional actions above Settings',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final coordinator = _ControllableCoordinator();
    await tester.pumpWidget(
      App(
        apiService: ApiService(serverUrl: 'https://damsure.nandakrishnan.in'),
        updateCoordinator: coordinator,
      ),
    );
    await tester.pump();
    final normalContext = tester.element(find.byType(SplashScreen));
    Navigator.of(normalContext).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(coordinator.manualChecks, 1);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(coordinator.optionalDismissals, 1);
    expect(find.text('Update available'), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update now'));
    await tester.pump();
    expect(coordinator.installRequests, 1);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  });
}
