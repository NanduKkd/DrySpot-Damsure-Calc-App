import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../updates/update_coordinator.dart';
import '../../updates/update_state.dart';

class UpdateGateScreen extends StatelessWidget {
  const UpdateGateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UpdateCoordinator>().state;
    final manifest = state.manifest;
    final required = state.policyStatus == UpdatePolicyStatus.required;
    final waitingForPermission =
        state.operation == UpdateOperationPhase.awaitingInstallPermission;
    final busy =
        state.operation == UpdateOperationPhase.downloading ||
        state.operation == UpdateOperationPhase.verifying ||
        state.operation == UpdateOperationPhase.launchingInstaller;
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('Update required'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.system_update, size: 64),
                const SizedBox(height: 24),
                Text(
                  required
                      ? 'Update DrySpot Uppala to continue'
                      : 'Update protection needs attention',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 12),
                Text(
                  required
                      ? manifest?.requiredUpdateReason ??
                            'A previously accepted update policy still requires an update.'
                      : 'The saved update policy could not be verified. Connect and retry before using the app.',
                  textAlign: TextAlign.center,
                ),
                if (manifest != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Version ${manifest.latestVersion} • ${_sizeLabel(manifest.sizeBytes)}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(manifest.releaseNotes, textAlign: TextAlign.center),
                ],
                if (state.failure != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _messageForFailure(state.failure!),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: busy || manifest == null
                      ? null
                      : () => context
                            .read<UpdateCoordinator>()
                            .downloadAndInstall(),
                  child: Text(
                    busy
                        ? 'Preparing update…'
                        : waitingForPermission
                        ? 'Allow installations'
                        : 'Download and install',
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => context.read<UpdateCoordinator>().retry(),
                  child: const Text('Retry update check'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OptionalUpdatePrompt extends StatelessWidget {
  const OptionalUpdatePrompt({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<UpdateCoordinator>().state;
    final manifest = state.manifest;
    if (state.policyStatus != UpdatePolicyStatus.optional ||
        !state.showOptionalPrompt ||
        manifest == null) {
      return const SizedBox.shrink();
    }
    final busy = state.operation != UpdateOperationPhase.idle;
    return Material(
      color: Colors.black54,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: AlertDialog(
            title: const Text('Update available'),
            content: SingleChildScrollView(
              child: ListBody(
                children: [
                  Text('Version ${manifest.latestVersion} is ready.'),
                  const SizedBox(height: 8),
                  Text(_sizeLabel(manifest.sizeBytes)),
                  const SizedBox(height: 12),
                  Text(manifest.releaseNotes),
                  if (state.failure != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _messageForFailure(state.failure!),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy
                    ? null
                    : () => context.read<UpdateCoordinator>().dismissOptional(),
                child: const Text('Later'),
              ),
              FilledButton(
                onPressed: busy
                    ? null
                    : () => context
                          .read<UpdateCoordinator>()
                          .downloadAndInstall(),
                child: Text(busy ? 'Preparing…' : 'Update now'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _sizeLabel(int bytes) =>
    '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

String _messageForFailure(UpdateFailureKind failure) => switch (failure) {
  UpdateFailureKind.network || UpdateFailureKind.timeout =>
    'Could not reach the update service. Check your connection and retry.',
  UpdateFailureKind.transport ||
  UpdateFailureKind.malformed ||
  UpdateFailureKind.rollback =>
    'The update response could not be trusted. Your existing policy remains in effect.',
  UpdateFailureKind.storage =>
    'Secure update information could not be saved. Free storage and retry.',
  UpdateFailureKind.insufficientSpace =>
    'There is not enough private device storage for this update.',
  UpdateFailureKind.artifactTooLarge ||
  UpdateFailureKind.sizeMismatch ||
  UpdateFailureKind.hashMismatch =>
    'The downloaded update could not be verified and was removed.',
  UpdateFailureKind.packageMismatch ||
  UpdateFailureKind.versionMismatch ||
  UpdateFailureKind.certificateMismatch =>
    'The downloaded update is not an approved DrySpot Uppala release.',
  UpdateFailureKind.permissionDenied =>
    'Allow DrySpot Uppala to install this update in Android settings.',
  UpdateFailureKind.installerUnavailable =>
    'Android package installation is unavailable on this device.',
  UpdateFailureKind.unexpected => 'The update could not be completed. Retry.',
};
