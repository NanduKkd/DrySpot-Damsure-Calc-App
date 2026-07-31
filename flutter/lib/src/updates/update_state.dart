import 'release_manifest.dart';

/// Policy, operation, and failure are deliberately independent. In
/// particular, a download failure must not erase a cached required policy.
enum UpdatePolicyStatus {
  starting,
  checking,
  current,
  disabled,
  optional,
  required,
  noValidatedPolicy,
  storageFailure,
}

enum UpdateOperationPhase {
  idle,
  downloading,
  verifying,
  readyToInstall,
  awaitingInstallPermission,
  launchingInstaller,
}

enum UpdateFailureKind {
  network,
  timeout,
  transport,
  malformed,
  rollback,
  storage,
  insufficientSpace,
  artifactTooLarge,
  sizeMismatch,
  hashMismatch,
  packageMismatch,
  versionMismatch,
  certificateMismatch,
  permissionDenied,
  installerUnavailable,
  unexpected,
}

class UpdateViewState {
  const UpdateViewState({
    required this.policyStatus,
    this.operation = UpdateOperationPhase.idle,
    this.failure,
    this.manifest,
    this.trustedResponseAt,
    this.showOptionalPrompt = false,
    this.isChecking = false,
  });

  const UpdateViewState.starting()
      : policyStatus = UpdatePolicyStatus.starting,
        operation = UpdateOperationPhase.idle,
        failure = null,
        manifest = null,
        trustedResponseAt = null,
        showOptionalPrompt = false,
        isChecking = true;

  final UpdatePolicyStatus policyStatus;
  final UpdateOperationPhase operation;
  final UpdateFailureKind? failure;
  final AvailableReleaseManifest? manifest;
  final DateTime? trustedResponseAt;
  final bool showOptionalPrompt;
  final bool isChecking;

  bool get isStartupPending => policyStatus == UpdatePolicyStatus.starting ||
      policyStatus == UpdatePolicyStatus.checking;

  bool get blocksNormalFlow =>
      isStartupPending ||
      policyStatus == UpdatePolicyStatus.required ||
      policyStatus == UpdatePolicyStatus.storageFailure;

  bool get hasRequiredPolicy => policyStatus == UpdatePolicyStatus.required;

  UpdateViewState copyWith({
    UpdatePolicyStatus? policyStatus,
    UpdateOperationPhase? operation,
    UpdateFailureKind? failure,
    bool clearFailure = false,
    AvailableReleaseManifest? manifest,
    bool clearManifest = false,
    DateTime? trustedResponseAt,
    bool clearTrustedResponseAt = false,
    bool? showOptionalPrompt,
    bool? isChecking,
  }) {
    return UpdateViewState(
      policyStatus: policyStatus ?? this.policyStatus,
      operation: operation ?? this.operation,
      failure: clearFailure ? null : failure ?? this.failure,
      manifest: clearManifest ? null : manifest ?? this.manifest,
      trustedResponseAt: clearTrustedResponseAt
          ? null
          : trustedResponseAt ?? this.trustedResponseAt,
      showOptionalPrompt: showOptionalPrompt ?? this.showOptionalPrompt,
      isChecking: isChecking ?? this.isChecking,
    );
  }
}
