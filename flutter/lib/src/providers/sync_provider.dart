import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../services/api_service.dart';
import '../services/session_manager.dart';
import '../services/sync_service.dart';

enum SyncRecoveryAction {
  none,
  retry,
  signInAgain,
  reviewRecord,
  contactAdministrator,
  updateRequired,
  restorePhoto,
}

enum SyncViewKind { idle, running, completed, needsAttention }

@immutable
class SyncNotice {
  const SyncNotice({required this.code, this.collection, this.createdAt});

  final String code;
  final String? collection;
  final DateTime? createdAt;

  bool get isInformational =>
      code == 'applied' ||
      code == 'already_applied' ||
      code == 'superseded' ||
      code == 'permanently_deleted';

  String get message => switch (code) {
        'applied' => 'Changes synced.',
        'already_applied' => 'Previously synced; no duplicate was created.',
        'superseded' =>
          'A newer edit was already saved. The newer version is kept.',
        'rejected' => 'A change needs review before it can be synced.',
        'permanently_deleted' =>
          'A warranty was permanently deleted on another device and cannot be restored.',
        'unauthorized' =>
          'This account cannot sync a record. Contact an administrator.',
        'network' =>
          'No connection or the request timed out. Retry when ready.',
        'authentication' => 'Your session has ended. Sign in again.',
        'authorization' =>
          'This account is not authorised to sync this work. Contact an administrator.',
        'validation' => 'A change needs review before it can be synced.',
        'required_update' =>
          'An app update is required before syncing can continue.',
        'local_storage' =>
          'A local photo or saved record could not be read. Restore or re-add it before retrying.',
        'idempotency_conflict' =>
          'This photo upload no longer matches the saved upload operation. Restore or re-add the photo before retrying.',
        'uploaded_asset_deleted' =>
          'This uploaded photo was removed. Restore or re-add the photo before retrying.',
        _ => 'Sync could not finish safely. Retry when ready.',
      };
}

@immutable
class SyncViewState {
  const SyncViewState({
    required this.kind,
    this.phase,
    this.lastAttemptAt,
    this.lastSuccessfulAt,
    this.pendingRecordCount = 0,
    this.pendingPhotoCount = 0,
    this.notices = const [],
    this.recoveryAction = SyncRecoveryAction.none,
  });

  const SyncViewState.empty() : this(kind: SyncViewKind.idle);

  final SyncViewKind kind;
  final SyncPhase? phase;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessfulAt;
  final int pendingRecordCount;
  final int pendingPhotoCount;
  final List<SyncNotice> notices;
  final SyncRecoveryAction recoveryAction;

  bool get isRunning => kind == SyncViewKind.running;
  bool get needsAttention => kind == SyncViewKind.needsAttention;

  SyncViewState copyWith({
    SyncViewKind? kind,
    Object? phase = _absent,
    Object? lastAttemptAt = _absent,
    Object? lastSuccessfulAt = _absent,
    int? pendingRecordCount,
    int? pendingPhotoCount,
    List<SyncNotice>? notices,
    SyncRecoveryAction? recoveryAction,
  }) =>
      SyncViewState(
        kind: kind ?? this.kind,
        phase: identical(phase, _absent) ? this.phase : phase as SyncPhase?,
        lastAttemptAt: identical(lastAttemptAt, _absent)
            ? this.lastAttemptAt
            : lastAttemptAt as DateTime?,
        lastSuccessfulAt: identical(lastSuccessfulAt, _absent)
            ? this.lastSuccessfulAt
            : lastSuccessfulAt as DateTime?,
        pendingRecordCount: pendingRecordCount ?? this.pendingRecordCount,
        pendingPhotoCount: pendingPhotoCount ?? this.pendingPhotoCount,
        notices: notices ?? this.notices,
        recoveryAction: recoveryAction ?? this.recoveryAction,
      );
}

const _absent = Object();

class SyncProvider extends ChangeNotifier {
  final SyncService _syncService;
  SessionSnapshot? _session;
  Future<void>? _activeRun;
  Future<void> Function()? _onAuthenticationExpired;
  SyncViewState _viewState = const SyncViewState.empty();

  SyncProvider({required SyncService syncService})
      : _syncService = syncService {
    _syncService.sessionManager?.addInvalidationListener(_clearForInvalidation);
  }

  SyncViewState get viewState => _viewState;

  // Compatibility accessors kept for existing callers while all new UI uses
  // the immutable view state.
  bool get isSyncing => _viewState.isRunning;
  String? get lastSyncTime => _viewState.lastSuccessfulAt?.toIso8601String();
  String? get error =>
      _viewState.needsAttention && _viewState.notices.isNotEmpty
          ? _viewState.notices.first.message
          : null;

  void updateSession(
    SessionSnapshot? session, {
    Future<void> Function()? onAuthenticationExpired,
  }) {
    _onAuthenticationExpired = onAuthenticationExpired;
    if (_sameSession(_session, session)) return;
    _session = session;
    _activeRun = null;
    _viewState = const SyncViewState.empty();
    notifyListeners();
    if (session != null) unawaited(_hydrate(session));
  }

  void _clearForInvalidation() {
    _session = null;
    _activeRun = null;
    _viewState = const SyncViewState.empty();
    notifyListeners();
  }

  bool _sameSession(SessionSnapshot? a, SessionSnapshot? b) =>
      a?.generation == b?.generation && a?.franchiseeId == b?.franchiseeId;

  bool _isCurrent(SessionSnapshot session) =>
      _sameSession(_session, session) &&
      (_syncService.sessionManager?.isCurrent(session) ?? true);

  Future<void> _hydrate(SessionSnapshot session) async {
    try {
      final values = await Future.wait<dynamic>([
        _syncService.dbService.getSyncRecoveryState(session.franchiseeId),
        _syncService.dbService.getSyncRecoveryCounts(session.franchiseeId),
      ]);
      if (!_isCurrent(session)) return;
      final state = Map<String, dynamic>.from(values[0] as Map);
      final counts = Map<String, int>.from(values[1] as Map);
      final notices = _notices(state['notices']);
      _viewState = SyncViewState(
        kind: _kindFor(notices),
        lastAttemptAt: _parseTime(state['last_attempt_at']),
        lastSuccessfulAt: _parseTime(state['last_successful_at']),
        pendingRecordCount: counts['dirty_records'] ?? 0,
        pendingPhotoCount: counts['pending_photos'] ?? 0,
        notices: notices,
        recoveryAction: _actionForNotices(notices),
      );
      notifyListeners();
    } on Object {
      // Status visibility must not make the regular APP-111 sync path fail.
    }
  }

  Future<void> refresh() async {
    final session = _session;
    if (session == null || _viewState.isRunning) return;
    await _hydrate(session);
  }

  Future<void> sync() {
    final active = _activeRun;
    if (active != null) return active;
    late final Future<void> run;
    run = _run().whenComplete(() {
      if (identical(_activeRun, run)) _activeRun = null;
    });
    _activeRun = run;
    return run;
  }

  Future<void> _run() async {
    final session = _session;
    if (session == null) return;
    final startedAt = DateTime.now().toUtc();
    _viewState = _viewState.copyWith(
      kind: SyncViewKind.running,
      phase: SyncPhase.preparing,
      lastAttemptAt: startedAt,
      recoveryAction: SyncRecoveryAction.none,
    );
    notifyListeners();

    try {
      await _syncService.dbService.recordSyncAttemptForSession(
        session.franchiseeId,
        at: startedAt,
        isSessionCurrent: () => _isCurrent(session),
      );
      if (!_isCurrent(session)) return;
      final result = await _syncService.sync(session, (phase) {
        if (!_isCurrent(session)) return;
        _viewState = _viewState.copyWith(phase: phase);
        notifyListeners();
      });
      if (!_isCurrent(session)) return;
      final notices = [
        for (final outcome in result.outcomes)
          SyncNotice(
            code: outcome.status.wireName,
            collection: outcome.collection,
          ),
      ];
      final attention = notices.any(
        (notice) => notice.code == 'rejected' || notice.code == 'unauthorized',
      );
      final completedAt = DateTime.now().toUtc();
      await _syncService.dbService.recordSyncRecoveryForSession(
        session.franchiseeId,
        successfulAt: completedAt,
        notices: [
          for (final notice in notices)
            {'code': notice.code, 'collection': notice.collection ?? ''},
        ],
        isSessionCurrent: () => _isCurrent(session),
      );
      if (!_isCurrent(session)) return;
      await _setFinished(
        session,
        kind: attention ? SyncViewKind.needsAttention : SyncViewKind.completed,
        notices: notices,
        recoveryAction: _actionForNotices(notices),
        successfulAt: completedAt,
      );
    } on StaleSessionException {
      // APP-106 owns the invalidation; stale work is intentionally invisible.
    } on Object catch (error) {
      if (!_isCurrent(session)) return;
      final notice = _noticeForError(error);
      try {
        await _syncService.dbService.recordSyncRecoveryForSession(
          session.franchiseeId,
          notices: [
            {'code': notice.code, 'collection': notice.collection ?? ''},
          ],
          isSessionCurrent: () => _isCurrent(session),
        );
      } on StaleSessionException {
        return;
      }
      if (!_isCurrent(session)) return;
      await _setFinished(
        session,
        kind: SyncViewKind.needsAttention,
        notices: [notice],
        recoveryAction: _actionForNotices([notice]),
      );
      if (notice.code == 'authentication' && _onAuthenticationExpired != null) {
        await _onAuthenticationExpired!();
      }
    }
  }

  Future<void> _setFinished(
    SessionSnapshot session, {
    required SyncViewKind kind,
    required List<SyncNotice> notices,
    required SyncRecoveryAction recoveryAction,
    DateTime? successfulAt,
  }) async {
    final counts = await _syncService.dbService.getSyncRecoveryCounts(
      session.franchiseeId,
    );
    if (!_isCurrent(session)) return;
    _viewState = _viewState.copyWith(
      kind: kind,
      phase: null,
      lastSuccessfulAt: successfulAt ?? _viewState.lastSuccessfulAt,
      pendingRecordCount: counts['dirty_records'] ?? 0,
      pendingPhotoCount: counts['pending_photos'] ?? 0,
      notices: notices,
      recoveryAction: recoveryAction,
    );
    notifyListeners();
  }

  List<SyncNotice> _notices(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map && entry['code'] is String)
          SyncNotice(
            code: entry['code'] as String,
            collection: entry['collection'] as String?,
            createdAt: _parseTime(entry['created_at']),
          ),
    ];
  }

  DateTime? _parseTime(Object? value) =>
      value is String ? DateTime.tryParse(value)?.toUtc() : null;

  SyncViewKind _kindFor(List<SyncNotice> notices) => notices.any(
        (notice) =>
            notice.code == 'rejected' ||
            notice.code == 'unauthorized' ||
            !notice.isInformational,
      )
          ? SyncViewKind.needsAttention
          : SyncViewKind.idle;

  SyncRecoveryAction _actionForNotices(List<SyncNotice> notices) {
    final codes = notices.map((notice) => notice.code).toSet();
    if (codes.contains('required_update')) {
      return SyncRecoveryAction.updateRequired;
    }
    if (codes.contains('authentication')) return SyncRecoveryAction.signInAgain;
    if (codes.contains('unauthorized') || codes.contains('authorization')) {
      return SyncRecoveryAction.contactAdministrator;
    }
    if (codes.contains('rejected') || codes.contains('validation')) {
      return SyncRecoveryAction.reviewRecord;
    }
    if (codes.contains('local_storage') ||
        codes.contains('idempotency_conflict') ||
        codes.contains('uploaded_asset_deleted')) {
      return SyncRecoveryAction.restorePhoto;
    }
    if (codes.contains('network') || codes.contains('protocol')) {
      return SyncRecoveryAction.retry;
    }
    return SyncRecoveryAction.none;
  }

  SyncNotice _noticeForError(Object error) {
    if (error is ApiException) {
      if (error.statusCode == 401) {
        return const SyncNotice(code: 'authentication');
      }
      if (error.statusCode == 403 || error.code == 'unauthorized') {
        return const SyncNotice(code: 'authorization');
      }
      if (error.statusCode == 426 || error.code == 'required_update') {
        return const SyncNotice(code: 'required_update');
      }
      if (error.statusCode == 409 && error.code == 'idempotency_conflict') {
        return const SyncNotice(code: 'idempotency_conflict');
      }
      if (error.statusCode == 410 && error.code == 'uploaded_asset_deleted') {
        return const SyncNotice(code: 'uploaded_asset_deleted');
      }
      if (error.statusCode == 400 || error.statusCode == 422) {
        return const SyncNotice(code: 'validation');
      }
      if (error.message.startsWith('Sync protocol error')) {
        return const SyncNotice(code: 'protocol');
      }
    }
    if (error is TimeoutException || error is SocketException) {
      return const SyncNotice(code: 'network');
    }
    if (error is FileSystemException || error is FormatException) {
      return const SyncNotice(code: 'local_storage');
    }
    return const SyncNotice(code: 'protocol');
  }

  @override
  void dispose() {
    _syncService.sessionManager
        ?.removeInvalidationListener(_clearForInvalidation);
    super.dispose();
  }
}
