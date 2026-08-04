import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/client_provider.dart';
import '../../providers/sync_provider.dart';
import '../../services/sync_service.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sync status')),
      body: Consumer<SyncProvider>(
        builder: (context, syncProvider, _) {
          final state = syncProvider.viewState;
          final action = _actionFor(state.recoveryAction);
          final updateBlocked =
              state.recoveryAction == SyncRecoveryAction.updateRequired;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Semantics(
                container: true,
                liveRegion: true,
                label: _statusLabel(state),
                child: Column(
                  children: [
                    Icon(_statusIcon(state), size: 64),
                    const SizedBox(height: 12),
                    Text(
                      _statusLabel(state),
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    if (state.phase != null) ...[
                      const SizedBox(height: 8),
                      Text('Current activity: ${_phaseLabel(state.phase!)}'),
                    ],
                    if (state.isRunning) ...[
                      const SizedBox(height: 16),
                      const CircularProgressIndicator(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 28),
              _StatusRow(
                label: 'Last successful sync',
                value: _timeLabel(state.lastSuccessfulAt),
              ),
              _StatusRow(
                label: 'Last attempted sync',
                value: _timeLabel(state.lastAttemptAt),
              ),
              _StatusRow(
                label: 'Pending records',
                value: '${state.pendingRecordCount}',
              ),
              _StatusRow(
                label: 'Pending photos',
                value: '${state.pendingPhotoCount}',
              ),
              if (state.notices.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text('Sync outcomes and recovery',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                for (final notice in state.notices)
                  Focus(
                    autofocus: state.needsAttention && !notice.isInformational,
                    child: Semantics(
                      container: true,
                      label: notice.message,
                      child: Card(
                        child: ListTile(
                          leading: Icon(
                            notice.isInformational
                                ? Icons.info_outline
                                : Icons.error_outline,
                          ),
                          title: Text(notice.message),
                          subtitle: notice.collection == null ||
                                  notice.collection!.isEmpty
                              ? null
                              : Text('Affected ${notice.collection} record'),
                        ),
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 28),
              Semantics(
                button: true,
                label: state.isRunning
                    ? 'Sync in progress. Repeated sync requests are ignored.'
                    : updateBlocked
                        ? 'Sync blocked. An app update is required. Use update guidance.'
                        : 'Sync now',
                child: FilledButton.icon(
                  onPressed: state.isRunning || updateBlocked
                      ? null
                      : () => _runSync(context, syncProvider),
                  icon: const Icon(Icons.sync),
                  label: Text(updateBlocked
                      ? 'Sync blocked until update'
                      : state.recoveryAction == SyncRecoveryAction.retry
                          ? 'Retry sync'
                          : 'Sync now'),
                ),
              ),
              if (action != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  button: true,
                  label: action.semanticsLabel ?? action.label,
                  child: OutlinedButton.icon(
                    onPressed: state.isRunning
                        ? null
                        : () => _recover(context, syncProvider, action),
                    icon: Icon(action.icon),
                    label: Text(action.label),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _runSync(
    BuildContext context,
    SyncProvider syncProvider,
  ) async {
    await syncProvider.sync();
    if (!context.mounted) return;
    await context.read<ClientProvider>().loadClients();
  }

  Future<void> _recover(
    BuildContext context,
    SyncProvider syncProvider,
    _RecoveryAction action,
  ) async {
    switch (action.kind) {
      case _RecoveryKind.retry:
        await _runSync(context, syncProvider);
        return;
      case _RecoveryKind.signIn:
        await syncProvider
            .performRecoveryAction(SyncRecoveryAction.signInAgain);
        return;
      case _RecoveryKind.update:
        await _showGuidance(
          context,
          title: 'Update required',
          message:
              'Sync is blocked until this app is updated. Install the approved update, then return and retry sync.',
        );
        return;
      case _RecoveryKind.contact:
        await _showGuidance(
          context,
          title: 'Contact administrator',
          message:
              'This account is not authorised to sync this work. Contact an administrator to review access, then retry only after access is restored.',
        );
        return;
      case _RecoveryKind.review:
      case _RecoveryKind.restore:
        await _showGuidance(
          context,
          title: action.kind == _RecoveryKind.review
              ? 'Review affected records'
              : 'Restore or re-add photo',
          message: action.kind == _RecoveryKind.review
              ? 'Review the affected record, correct it if needed, then retry sync manually.'
              : 'Restore the original photo or remove and add it again, then retry sync manually.',
        );
    }
  }

  Future<void> _showGuidance(
    BuildContext context, {
    required String title,
    required String message,
  }) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );

  _RecoveryAction? _actionFor(SyncRecoveryAction action) => switch (action) {
        SyncRecoveryAction.retry => const _RecoveryAction(
            kind: _RecoveryKind.retry,
            label: 'Retry now',
            icon: Icons.refresh,
          ),
        SyncRecoveryAction.reviewRecord => const _RecoveryAction(
            kind: _RecoveryKind.review,
            label: 'Review affected records',
            icon: Icons.edit_outlined,
          ),
        SyncRecoveryAction.restorePhoto => const _RecoveryAction(
            kind: _RecoveryKind.restore,
            label: 'Restore or re-add photo',
            icon: Icons.photo_outlined,
          ),
        SyncRecoveryAction.signInAgain => const _RecoveryAction(
            kind: _RecoveryKind.signIn,
            label: 'Sign in again',
            semanticsLabel: 'Sign in again to continue syncing',
            icon: Icons.login,
          ),
        SyncRecoveryAction.contactAdministrator => const _RecoveryAction(
            kind: _RecoveryKind.contact,
            label: 'Contact administrator',
            semanticsLabel: 'Contact an administrator about sync access',
            icon: Icons.support_agent,
          ),
        SyncRecoveryAction.updateRequired => const _RecoveryAction(
            kind: _RecoveryKind.update,
            label: 'View update guidance',
            semanticsLabel: 'View required update guidance',
            icon: Icons.system_update_alt,
          ),
        _ => null,
      };

  String _statusLabel(SyncViewState state) => switch (state.kind) {
        SyncViewKind.running => 'Sync in progress',
        SyncViewKind.completed => 'Sync completed',
        SyncViewKind.needsAttention => 'Sync needs attention',
        SyncViewKind.idle => 'Sync ready',
      };

  IconData _statusIcon(SyncViewState state) => switch (state.kind) {
        SyncViewKind.running => Icons.sync,
        SyncViewKind.completed => Icons.check_circle_outline,
        SyncViewKind.needsAttention => Icons.warning_amber_outlined,
        SyncViewKind.idle => Icons.cloud_sync_outlined,
      };

  String _phaseLabel(SyncPhase phase) => switch (phase) {
        SyncPhase.preparing => 'Preparing',
        SyncPhase.uploadingPhotos => 'Uploading photos',
        SyncPhase.sendingChanges => 'Sending changes',
        SyncPhase.applyingUpdates => 'Applying updates',
        SyncPhase.finalising => 'Finalising',
      };

  String _timeLabel(DateTime? time) =>
      time == null ? 'Never' : time.toLocal().toString().split('.').first;
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value, semanticsLabel: '$label: $value'),
          ],
        ),
      );
}

enum _RecoveryKind { retry, review, restore, signIn, update, contact }

class _RecoveryAction {
  const _RecoveryAction({
    required this.kind,
    required this.label,
    required this.icon,
    this.semanticsLabel,
  });

  final _RecoveryKind kind;
  final String label;
  final IconData icon;
  final String? semanticsLabel;
}
