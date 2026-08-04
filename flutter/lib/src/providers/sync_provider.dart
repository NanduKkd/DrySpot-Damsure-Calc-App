import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../services/api_service.dart';
import '../services/db_service.dart';
import '../services/session_manager.dart';
import '../services/sync_connection_monitor.dart';
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
        'connection_restored' =>
          'Connection restored. Review the pending work, then retry sync when ready.',
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

/// Narrow injection seam for the APP-112 status projection. APP-111 data and
/// cursor transactions remain in SyncService; this only makes UI settlement
/// deterministic when the status projection itself cannot access SQLite.
abstract interface class SyncStatusStore {
  Future<Map<String, dynamic>> state(String franchiseeId);
  Future<Map<String, int>> counts(String franchiseeId);
  Future<void> recordAttempt(
    SessionSnapshot session, {
    required DateTime at,
    required bool Function() isSessionCurrent,
  });
  Future<void> recordRecovery(
    SessionSnapshot session, {
    DateTime? successfulAt,
    required List<Map<String, String>> notices,
    required bool Function() isSessionCurrent,
  });
}

class DbSyncStatusStore implements SyncStatusStore {
  const DbSyncStatusStore(this._db);

  final DbService _db;

  @override
  Future<Map<String, int>> counts(String franchiseeId) =>
      _db.getSyncRecoveryCounts(franchiseeId);

  @override
  Future<void> recordAttempt(
    SessionSnapshot session, {
    required DateTime at,
    required bool Function() isSessionCurrent,
  }) =>
      _db.recordSyncAttemptForSession(
        session.franchiseeId,
        at: at,
        isSessionCurrent: isSessionCurrent,
      );

  @override
  Future<void> recordRecovery(
    SessionSnapshot session, {
    DateTime? successfulAt,
    required List<Map<String, String>> notices,
    required bool Function() isSessionCurrent,
  }) =>
      _db.recordSyncRecoveryForSession(
        session.franchiseeId,
        successfulAt: successfulAt,
        notices: notices,
        isSessionCurrent: isSessionCurrent,
      );

  @override
  Future<Map<String, dynamic>> state(String franchiseeId) =>
      _db.getSyncRecoveryState(franchiseeId);
}

class SyncProvider extends ChangeNotifier {
  final SyncService _syncService;
  final SyncConnectionMonitor _connectionMonitor;
  final SyncStatusStore _statusStore;
  SessionSnapshot? _session;
  SessionSnapshot? _networkFailureSession;
  Future<void>? _activeRun;
  Future<void> Function()? _onAuthenticationExpired;
  late final StreamSubscription<bool> _connectionSubscription;
  bool _disposed = false;
  SyncViewState _viewState = const SyncViewState.empty();

  SyncProvider({
    required SyncService syncService,
    SyncConnectionMonitor? connectionMonitor,
    SyncStatusStore? statusStore,
  })  : _syncService = syncService,
        _connectionMonitor =
            connectionMonitor ?? PlatformSyncConnectionMonitor(),
        _statusStore = statusStore ?? DbSyncStatusStore(syncService.dbService) {
    _syncService.sessionManager?.addInvalidationListener(_clearForInvalidation);
    _connectionSubscription = _connectionMonitor.connectionChanges.listen(
      _onConnectionChanged,
    );
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
    _networkFailureSession = null;
    _viewState = const SyncViewState.empty();
    notifyListeners();
    if (session != null) unawaited(_hydrate(session));
  }

  void _clearForInvalidation() {
    _session = null;
    _activeRun = null;
    _networkFailureSession = null;
    _viewState = const SyncViewState.empty();
    notifyListeners();
  }

  bool _sameSession(SessionSnapshot? a, SessionSnapshot? b) =>
      a?.generation == b?.generation && a?.franchiseeId == b?.franchiseeId;

  bool _isCurrent(SessionSnapshot session) =>
      !_disposed &&
      _sameSession(_session, session) &&
      (_syncService.sessionManager?.isCurrent(session) ?? true);

  Future<void> _hydrate(SessionSnapshot session) async {
    try {
      final values = await Future.wait<dynamic>([
        _statusStore.state(session.franchiseeId),
        _statusStore.counts(session.franchiseeId),
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
    if (_viewState.recoveryAction == SyncRecoveryAction.updateRequired) {
      return Future<void>.value();
    }
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
      await _statusStore.recordAttempt(
        session,
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
      final persistenceNotice = await _recordRecoveryBestEffort(
        session,
        successfulAt: completedAt,
        notices: [
          for (final notice in notices)
            {'code': notice.code, 'collection': notice.collection ?? ''},
        ],
      );
      if (!_isCurrent(session)) return;
      if (persistenceNotice != null) {
        await _setFinished(
          session,
          kind: SyncViewKind.needsAttention,
          notices: [persistenceNotice],
          recoveryAction: _actionForNotices([persistenceNotice]),
        );
        return;
      }
      _networkFailureSession = null;
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
      var notice = _noticeForError(error);
      SyncNotice? persistenceNotice;
      try {
        persistenceNotice = await _recordRecoveryBestEffort(
          session,
          notices: [
            {'code': notice.code, 'collection': notice.collection ?? ''},
          ],
        );
      } on StaleSessionException {
        return;
      }
      if (persistenceNotice != null) notice = persistenceNotice;
      if (!_isCurrent(session)) return;
      await _setFinished(
        session,
        kind: SyncViewKind.needsAttention,
        notices: [notice],
        recoveryAction: _actionForNotices([notice]),
      );
      if (notice.code == 'network') {
        _networkFailureSession = session;
      } else {
        _networkFailureSession = null;
      }
    }
  }

  Future<SyncNotice?> _recordRecoveryBestEffort(
    SessionSnapshot session, {
    DateTime? successfulAt,
    required List<Map<String, String>> notices,
  }) async {
    try {
      await _statusStore.recordRecovery(
        session,
        successfulAt: successfulAt,
        notices: notices,
        isSessionCurrent: () => _isCurrent(session),
      );
      return null;
    } on StaleSessionException {
      rethrow;
    } on Object catch (error) {
      return _noticeForError(error);
    }
  }

  Future<void> _setFinished(
    SessionSnapshot session, {
    required SyncViewKind kind,
    required List<SyncNotice> notices,
    required SyncRecoveryAction recoveryAction,
    DateTime? successfulAt,
  }) async {
    Map<String, int> counts;
    try {
      counts = await _statusStore.counts(session.franchiseeId);
    } on Object catch (error) {
      if (!_isCurrent(session)) return;
      final storageNotice = _noticeForError(error);
      try {
        await _recordRecoveryBestEffort(
          session,
          notices: [
            {
              'code': storageNotice.code,
              'collection': storageNotice.collection ?? '',
            },
          ],
        );
      } on StaleSessionException {
        return;
      }
      if (!_isCurrent(session)) return;
      _publishFinished(
        kind: SyncViewKind.needsAttention,
        notices: [storageNotice],
        recoveryAction: SyncRecoveryAction.restorePhoto,
        successfulAt: successfulAt,
      );
      return;
    }
    if (!_isCurrent(session)) return;
    _publishFinished(
      kind: kind,
      notices: notices,
      recoveryAction: recoveryAction,
      successfulAt: successfulAt,
      counts: counts,
    );
  }

  void _publishFinished({
    required SyncViewKind kind,
    required List<SyncNotice> notices,
    required SyncRecoveryAction recoveryAction,
    DateTime? successfulAt,
    Map<String, int>? counts,
  }) {
    _viewState = _viewState.copyWith(
      kind: kind,
      phase: null,
      lastSuccessfulAt: successfulAt ?? _viewState.lastSuccessfulAt,
      pendingRecordCount:
          counts?['dirty_records'] ?? _viewState.pendingRecordCount,
      pendingPhotoCount:
          counts?['pending_photos'] ?? _viewState.pendingPhotoCount,
      notices: notices,
      recoveryAction: recoveryAction,
    );
    notifyListeners();
  }

  void _onConnectionChanged(bool connected) {
    if (!connected) return;
    final session = _networkFailureSession;
    if (session == null) return;
    if (!_isCurrent(session)) {
      _networkFailureSession = null;
      return;
    }
    _networkFailureSession = null;
    unawaited(_publishConnectionRestored(session));
  }

  Future<void> _publishConnectionRestored(SessionSnapshot session) async {
    if (!_isCurrent(session)) return;
    const notice = SyncNotice(code: 'connection_restored');
    SyncNotice? persistenceNotice;
    try {
      persistenceNotice = await _recordRecoveryBestEffort(
        session,
        notices: const [
          {'code': 'connection_restored', 'collection': ''},
        ],
      );
    } on StaleSessionException {
      return;
    }
    if (!_isCurrent(session)) return;
    final current = persistenceNotice ?? notice;
    await _setFinished(
      session,
      kind: SyncViewKind.needsAttention,
      notices: [current],
      recoveryAction: _actionForNotices([current]),
    );
  }

  /// Only the fenced APP-106 logout action has an external side effect. The
  /// other recovery actions are navigational/operator guidance and must never
  /// silently retry a request.
  Future<void> performRecoveryAction(SyncRecoveryAction action) async {
    if (action != SyncRecoveryAction.signInAgain ||
        _viewState.recoveryAction != action) {
      return;
    }
    final session = _session;
    final callback = _onAuthenticationExpired;
    if (session == null || callback == null || !_isCurrent(session)) return;
    await callback();
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
    if (codes.contains('network') ||
        codes.contains('connection_restored') ||
        codes.contains('protocol')) {
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
    if (error is DatabaseException ||
        error is FileSystemException ||
        error is FormatException) {
      return const SyncNotice(code: 'local_storage');
    }
    return const SyncNotice(code: 'protocol');
  }

  @override
  void dispose() {
    _disposed = true;
    _syncService.sessionManager
        ?.removeInvalidationListener(_clearForInvalidation);
    _connectionSubscription.cancel();
    super.dispose();
  }
}
