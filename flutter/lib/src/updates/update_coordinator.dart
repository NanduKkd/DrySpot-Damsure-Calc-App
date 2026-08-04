import 'dart:async';
import 'package:flutter/foundation.dart';

import 'android_update_bridge.dart';
import 'release_manifest.dart';
import 'update_artifact_service.dart';
import 'update_policy_store.dart';
import 'update_state.dart';
import 'update_transport.dart';

/// Serializes APP-113 policy, download, and installer operations. The cached
/// policy is authoritative for required/offline behaviour; a downloaded file
/// is deliberately not.
class UpdateCoordinator extends ChangeNotifier {
  UpdateCoordinator({
    UpdatePolicyStore? policyStore,
    ReleaseManifestTransport? transport,
    UpdateArtifactService? artifactService,
    UpdatePlatformBridge? platform,
  })  : _policyStore = policyStore ?? UpdatePolicyStore(),
        _transport = transport ?? NetworkReleaseManifestTransport(),
        _platform = platform ?? MethodChannelUpdatePlatformBridge(),
        _artifactService = artifactService ??
            UpdateArtifactService(
              platform: platform ?? MethodChannelUpdatePlatformBridge(),
            );

  final UpdatePolicyStore _policyStore;
  final ReleaseManifestTransport _transport;
  final UpdateArtifactService _artifactService;
  final UpdatePlatformBridge _platform;

  UpdateViewState _state = const UpdateViewState.starting();
  UpdateViewState get state => _state;

  InstalledAndroidPackage? _installed;
  UpdateAcceptedPolicy? _accepted;
  UpdatePolicyLoadKind _loadKind = UpdatePolicyLoadKind.empty;
  Future<void>? _initialization;
  Future<void>? _checkFlight;
  Future<void>? _installFlight;
  Future<void>? _resumeFlight;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _installed = await _platform.installedPackage();
      if (_installed!.versionCode <= 0 || _installed!.versionName.isEmpty) {
        throw const FormatException('Installed version is invalid.');
      }
    } on Object {
      _setState(
        _state.copyWith(
          policyStatus: UpdatePolicyStatus.storageFailure,
          failure: UpdateFailureKind.unexpected,
          isChecking: false,
        ),
      );
      return;
    }

    final loaded = await _policyStore.load();
    _loadKind = loaded.kind;
    _accepted = loaded.acceptedPolicy;
    if (_accepted != null) {
      await _applyAcceptedPolicy(
        _accepted!,
        fromTrustedFetch: false,
        manual: false,
      );
    } else if (loaded.kind == UpdatePolicyLoadKind.corrupt ||
        loaded.kind == UpdatePolicyLoadKind.unavailable) {
      _setState(
        _state.copyWith(
          policyStatus: UpdatePolicyStatus.storageFailure,
          failure: UpdateFailureKind.storage,
          isChecking: true,
        ),
      );
    }
    await _recoverArtifacts(_availableManifestFromAccepted());
    await checkForUpdates();
  }

  Future<void> retry() => checkForUpdates(manual: true);

  /// Android returns from package-installer or unknown-sources settings through
  /// the app lifecycle. Re-read the installed package before deciding whether a
  /// verified cache can be removed or a required gate remains in force.
  Future<void> reconcileInstalledVersionAfterResume() {
    final existing = _resumeFlight;
    if (existing != null) return existing;
    final future = _reconcileInstalledVersionAfterResume();
    _resumeFlight = future;
    future.whenComplete(() {
      if (identical(_resumeFlight, future)) _resumeFlight = null;
    });
    return future;
  }

  Future<void> _reconcileInstalledVersionAfterResume() async {
    final accepted = _accepted;
    if (accepted == null) return;
    try {
      _installed = await _platform.installedPackage();
      await _applyAcceptedPolicy(
        accepted,
        fromTrustedFetch: false,
        manual: false,
      );
    } on Object {
      // A lifecycle recheck failure is never permission to relax policy.
    }
  }

  Future<void> checkForUpdates({bool manual = false}) {
    final active = _checkFlight;
    if (active != null) return active;
    final future = _check(manual);
    _checkFlight = future;
    future.whenComplete(() {
      if (identical(_checkFlight, future)) _checkFlight = null;
    });
    return future;
  }

  Future<void> _check(bool manual) async {
    if (_installed == null) return;
    _setState(_state.copyWith(isChecking: true, clearFailure: true));
    try {
      final response = await _transport.fetch();
      final parsed = ReleaseManifestParser.parse(
        response.document,
        trustedNowUtc: response.trustedResponseAt,
      );
      if (parsed is! ValidReleaseManifestResult) {
        await _finishRejected(UpdateFailureKind.malformed);
        return;
      }
      // There is no valid high-water mark to compare against after a corrupt
      // or unavailable atomic record.  Every network policy, including a
      // strict disabled v1 record, must therefore be rejected: replacing it
      // would make an unknown cached required policy disappear.
      if (_loadKind == UpdatePolicyLoadKind.corrupt ||
          _loadKind == UpdatePolicyLoadKind.unavailable) {
        await _finishRejected(UpdateFailureKind.rollback);
        return;
      }
      final highWater = _accepted?.highWater;
      if (!validateManifestHighWater(parsed, previous: highWater).isAccepted) {
        await _finishRejected(UpdateFailureKind.rollback);
        return;
      }
      final previousTrustedResponseAt = _accepted?.trustedResponseAt;
      if (previousTrustedResponseAt != null &&
          response.trustedResponseAt.toUtc().isBefore(
                previousTrustedResponseAt.toUtc(),
              )) {
        await _finishRejected(UpdateFailureKind.rollback);
        return;
      }
      final persisted = await _policyStore.accept(
        parsed,
        trustedResponseAt: response.trustedResponseAt,
      );
      // Strict v1 persistence happens before classification, auth restoration,
      // or any download. Legacy disabled is intentionally the sole null case.
      _accepted = persisted;
      _loadKind = UpdatePolicyLoadKind.valid;
      if (persisted == null) {
        _setState(
          const UpdateViewState(
            policyStatus: UpdatePolicyStatus.disabled,
            isChecking: false,
          ),
        );
        await _recoverArtifacts(null);
        return;
      }
      await _applyAcceptedPolicy(
        persisted,
        fromTrustedFetch: true,
        manual: manual,
      );
      if (persisted.policy is DisabledReleaseManifestResult) {
        await _recoverArtifacts(null);
      }
    } on UpdatePolicyStoreException {
      _setState(
        _state.copyWith(
          policyStatus: UpdatePolicyStatus.storageFailure,
          failure: UpdateFailureKind.storage,
          isChecking: false,
          clearManifest: true,
          clearTrustedResponseAt: true,
          showOptionalPrompt: false,
        ),
      );
    } on UpdateTransportException catch (error) {
      await _finishRejected(error.kind);
    } on Object {
      await _finishRejected(UpdateFailureKind.unexpected);
    }
  }

  Future<void> _applyAcceptedPolicy(
    UpdateAcceptedPolicy accepted, {
    required bool fromTrustedFetch,
    required bool manual,
  }) async {
    final classification = classifyReleaseUpdate(
      accepted.policy,
      installedVersionCode: _installed!.versionCode,
    );
    switch (classification.state) {
      case ReleaseUpdateState.required:
        _setState(
          UpdateViewState(
            policyStatus: UpdatePolicyStatus.required,
            manifest: classification.manifest,
            trustedResponseAt: accepted.trustedResponseAt,
            isChecking: false,
          ),
        );
      case ReleaseUpdateState.optional:
        final showPrompt = await _shouldPromptOptional(
          classification.manifest!,
          accepted.trustedResponseAt,
          fromTrustedFetch: fromTrustedFetch,
          manual: manual,
        );
        _setState(
          UpdateViewState(
            policyStatus: UpdatePolicyStatus.optional,
            manifest: classification.manifest,
            trustedResponseAt: accepted.trustedResponseAt,
            showOptionalPrompt: showPrompt,
            isChecking: false,
          ),
        );
      case ReleaseUpdateState.current:
        _setState(
          UpdateViewState(
            policyStatus: UpdatePolicyStatus.current,
            manifest: classification.manifest,
            trustedResponseAt: accepted.trustedResponseAt,
            isChecking: false,
          ),
        );
        await _recoverArtifacts(null);
      case ReleaseUpdateState.disabled:
        _setState(
          UpdateViewState(
            policyStatus: UpdatePolicyStatus.disabled,
            trustedResponseAt: accepted.trustedResponseAt,
            isChecking: false,
          ),
        );
      case ReleaseUpdateState.malformed:
        await _finishRejected(UpdateFailureKind.malformed);
    }
  }

  Future<bool> _shouldPromptOptional(
    AvailableReleaseManifest manifest,
    DateTime trustedTime, {
    required bool fromTrustedFetch,
    required bool manual,
  }) async {
    if (manual) return true;
    final dismissed = await _policyStore.loadDismissal();
    if (dismissed == null ||
        dismissed.targetVersionCode != manifest.latestVersionCode) {
      return true;
    }
    // Cached policy has no newer trusted time. It must not re-prompt merely
    // because the device wall clock changed or the app restarted.
    if (!fromTrustedFetch) return false;
    return !trustedTime.isBefore(
      dismissed.trustedDismissedAt.add(const Duration(hours: 24)),
    );
  }

  Future<void> dismissOptional() async {
    final manifest = _state.manifest;
    final trustedTime = _state.trustedResponseAt;
    if (_state.policyStatus != UpdatePolicyStatus.optional ||
        manifest == null ||
        trustedTime == null) {
      return;
    }
    try {
      await _policyStore.dismissOptional(
        manifest.latestVersionCode,
        trustedTime,
      );
      _setState(_state.copyWith(showOptionalPrompt: false, clearFailure: true));
    } on UpdatePolicyStoreException {
      _setState(_state.copyWith(failure: UpdateFailureKind.storage));
    }
  }

  Future<void> downloadAndInstall() {
    final inFlight = _installFlight;
    if (inFlight != null) return inFlight;
    final future = _downloadAndInstall();
    _installFlight = future;
    future.whenComplete(() {
      if (identical(_installFlight, future)) _installFlight = null;
    });
    return future;
  }

  Future<void> _downloadAndInstall() async {
    final manifest = _state.manifest;
    if (manifest == null ||
        (_state.policyStatus != UpdatePolicyStatus.optional &&
            _state.policyStatus != UpdatePolicyStatus.required)) {
      return;
    }
    var hasInstallerCandidate = false;
    try {
      if (!await _platform.canRequestPackageInstalls()) {
        _setState(
          _state.copyWith(
            operation: UpdateOperationPhase.awaitingInstallPermission,
            failure: UpdateFailureKind.permissionDenied,
          ),
        );
        await _platform.openUnknownSourcesSettings();
        return;
      }
      final file = await _artifactService.obtain(
        manifest,
        onPhase: (phase) =>
            _setState(_state.copyWith(operation: phase, clearFailure: true)),
      );
      hasInstallerCandidate = true;
      _setState(
        _state.copyWith(
          operation: UpdateOperationPhase.readyToInstall,
          clearFailure: true,
        ),
      );
      // Recheck after a return from unknown-sources settings and before the
      // second native package/certificate verification at installer handoff.
      if (!await _platform.canRequestPackageInstalls()) {
        _setState(
          _state.copyWith(
            operation: UpdateOperationPhase.awaitingInstallPermission,
            failure: UpdateFailureKind.permissionDenied,
          ),
        );
        return;
      }
      _setState(
        _state.copyWith(operation: UpdateOperationPhase.launchingInstaller),
      );
      final result = await _platform.launchInstaller(file, manifest);
      if (!result.isSuccess) {
        await _discardArtifactSafely(manifest);
        hasInstallerCandidate = false;
        throw UpdateArtifactException(_nativeFailure(result.failure));
      }
      // Keep the verified app-private file until a post-installer process
      // launch observes the upgraded installed version and recovery removes it.
      _setState(_state.copyWith(operation: UpdateOperationPhase.idle));
    } on UpdateArtifactException catch (error) {
      if (hasInstallerCandidate) await _discardArtifactSafely(manifest);
      _setState(
        _state.copyWith(
          operation: UpdateOperationPhase.idle,
          failure: error.kind,
        ),
      );
    } on Object {
      if (hasInstallerCandidate) await _discardArtifactSafely(manifest);
      _setState(
        _state.copyWith(
          operation: UpdateOperationPhase.idle,
          failure: UpdateFailureKind.unexpected,
        ),
      );
    }
  }

  Future<void> _discardArtifactSafely(AvailableReleaseManifest manifest) async {
    try {
      await _artifactService.discard(manifest);
    } on Object {
      // A rejected installer handoff is never reusable.  Keep reporting the
      // original verification/installer failure even if disposable-cache
      // cleanup encounters an OS error; recovery retries on the next launch.
    }
  }

  UpdateFailureKind _nativeFailure(
    AndroidUpdateFailure? failure,
  ) =>
      switch (failure) {
        AndroidUpdateFailure.packageMismatch =>
          UpdateFailureKind.packageMismatch,
        AndroidUpdateFailure.versionMismatch =>
          UpdateFailureKind.versionMismatch,
        AndroidUpdateFailure.certificateMismatch =>
          UpdateFailureKind.certificateMismatch,
        AndroidUpdateFailure.permissionDenied =>
          UpdateFailureKind.permissionDenied,
        AndroidUpdateFailure.installerUnavailable =>
          UpdateFailureKind.installerUnavailable,
        _ => UpdateFailureKind.unexpected,
      };

  AvailableReleaseManifest? _availableManifestFromAccepted() =>
      switch (_accepted?.policy) {
        AvailableReleaseManifestResult(:final manifest) => manifest,
        _ => null,
      };

  Future<void> _recoverArtifacts(AvailableReleaseManifest? manifest) async {
    try {
      await _artifactService.recover(manifest);
    } on Object {
      // An OS-managed cache is disposable. Its cleanup failure never clears a
      // policy and the next download will revalidate from byte zero.
    }
  }

  Future<void> _finishRejected(UpdateFailureKind failure) async {
    final accepted = _accepted;
    if (accepted != null) {
      // Reapply cached state without treating the rejected response as a new
      // trusted-time observation. A cached required policy can never relax.
      await _applyAcceptedPolicy(
        accepted,
        fromTrustedFetch: false,
        manual: false,
      );
      _setState(_state.copyWith(failure: failure, isChecking: false));
      return;
    }
    if (_loadKind == UpdatePolicyLoadKind.corrupt ||
        _loadKind == UpdatePolicyLoadKind.unavailable) {
      _setState(
        _state.copyWith(
          policyStatus: UpdatePolicyStatus.storageFailure,
          failure: failure == UpdateFailureKind.storage
              ? failure
              : UpdateFailureKind.storage,
          isChecking: false,
          clearManifest: true,
          clearTrustedResponseAt: true,
          showOptionalPrompt: false,
        ),
      );
      return;
    }
    _setState(
      UpdateViewState(
        policyStatus: UpdatePolicyStatus.noValidatedPolicy,
        failure: failure,
        isChecking: false,
      ),
    );
  }

  void _setState(UpdateViewState value) {
    _state = value;
    notifyListeners();
  }
}
