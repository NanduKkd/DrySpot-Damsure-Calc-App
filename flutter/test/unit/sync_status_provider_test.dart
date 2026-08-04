import 'dart:async';
import 'dart:io';

import 'package:app_client/src/providers/sync_provider.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/session_manager.dart';
import 'package:app_client/src/services/sync_connection_monitor.dart';
import 'package:app_client/src/services/sync_service.dart';
import 'package:app_client/src/screens/sync/sync_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TestConnectionMonitor implements SyncConnectionMonitor {
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  Stream<bool> get connectionChanges => _changes.stream;

  void emit(bool connected) => _changes.add(connected);

  Future<void> close() => _changes.close();
}

class _TestDatabaseException extends DatabaseException {
  _TestDatabaseException(super.message);

  @override
  int? getResultCode() => null;

  @override
  Object? get result => null;
}

class _FaultingStatusStore implements SyncStatusStore {
  bool failAttempt = false;
  bool failRecovery = false;
  bool failCounts = false;

  @override
  Future<Map<String, int>> counts(String franchiseeId) async {
    if (failCounts) throw _TestDatabaseException('count disk failure');
    return {'dirty_records': 0, 'pending_photos': 0};
  }

  @override
  Future<void> recordAttempt(
    SessionSnapshot session, {
    required DateTime at,
    required bool Function() isSessionCurrent,
  }) async {
    if (failAttempt) throw _TestDatabaseException('attempt disk failure');
  }

  @override
  Future<void> recordRecovery(
    SessionSnapshot session, {
    DateTime? successfulAt,
    required List<Map<String, String>> notices,
    required bool Function() isSessionCurrent,
  }) async {
    if (failRecovery) throw _TestDatabaseException('recovery disk failure');
  }

  @override
  Future<Map<String, dynamic>> state(String franchiseeId) async => {};
}

class _ScriptedSyncService extends SyncService {
  _ScriptedSyncService(DbService db)
      : super(apiService: ApiService(), dbService: db);

  int calls = 0;
  SyncRunResult result = const SyncRunResult();
  Object? failure;
  List<SyncPhase> phases = SyncPhase.values;
  Completer<void>? gate;
  final started = <Completer<void>>[];

  @override
  Future<SyncRunResult> sync([
    SessionSnapshot? requestedSession,
    SyncPhaseListener? onPhase,
  ]) async {
    calls += 1;
    final startedRun = Completer<void>();
    started.add(startedRun);
    for (final phase in phases) {
      onPhase?.call(phase);
    }
    startedRun.complete();
    if (gate != null) await gate!.future;
    if (failure != null) throw failure!;
    return result;
  }
}

class _StaticSyncProvider extends SyncProvider {
  _StaticSyncProvider(
    this._testState, {
    required SyncConnectionMonitor connectionMonitor,
  }) : super(
          syncService: SyncService(apiService: ApiService()),
          connectionMonitor: connectionMonitor,
        );

  final SyncViewState _testState;

  @override
  SyncViewState get viewState => _testState;

  @override
  Future<void> sync() async {}
}

const _tenant = 'tenant-a';

const _session = SessionSnapshot(
  token: 'token-a',
  userName: null,
  franchiseeId: _tenant,
  franchiseeName: null,
  generation: 1,
);

Future<Database> _openStatusDb() => openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
            'CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        await db.execute('''
          CREATE TABLE sync_notices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            franchisee_id TEXT NOT NULL, code TEXT NOT NULL,
            collection_name TEXT, entity_id TEXT, created_at TEXT NOT NULL
          )
        ''');
        await db.execute('''CREATE TABLE clients (
          local_id INTEGER PRIMARY KEY, remote_id TEXT, franchisee_id TEXT,
          is_dirty INTEGER DEFAULT 0, deleted_at TEXT, photos TEXT
        )''');
        await db.execute('''CREATE TABLE items (
          local_id INTEGER PRIMARY KEY, client_id INTEGER, is_dirty INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE rectangles (
          local_id INTEGER PRIMARY KEY, item_id INTEGER, is_dirty INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE default_prices (
          local_id INTEGER PRIMARY KEY, franchisee_id TEXT, is_dirty INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE warranties (
          local_id INTEGER PRIMARY KEY, client_id INTEGER, is_dirty INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE proposals (
          local_id INTEGER PRIMARY KEY, client_id INTEGER, is_dirty INTEGER DEFAULT 0
        )''');
        await db.execute('''CREATE TABLE pending_client_photos (
          franchisee_id TEXT, client_remote_id TEXT, local_path TEXT,
          upload_id TEXT, file_sha256 TEXT, canonical_url TEXT,
          status TEXT NOT NULL DEFAULT 'pending'
        )''');
      },
    );

Future<void> _waitForStart(_ScriptedSyncService service) async {
  while (service.started.isEmpty) {
    await Future<void>.delayed(Duration.zero);
  }
  await service.started.single.future;
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('APP-112 sync provider', () {
    late Database database;
    late DbService db;
    late _ScriptedSyncService service;
    late SyncProvider provider;
    late _TestConnectionMonitor connectionMonitor;

    setUp(() async {
      database = await _openStatusDb();
      db = DbService(database: database);
      service = _ScriptedSyncService(db);
      connectionMonitor = _TestConnectionMonitor();
      provider = SyncProvider(
        syncService: service,
        connectionMonitor: connectionMonitor,
      )..updateSession(_session);
      await provider.refresh();
    });

    tearDown(() async {
      provider.dispose();
      await connectionMonitor.close();
      await database.close();
    });

    test(
        'maps all six APP-111 outcomes and publishes the exact persisted completion time',
        () async {
      service.result = const SyncRunResult(
        outcomes: [
          SyncOutcome(collection: 'clients', status: SyncOutcomeStatus.applied),
          SyncOutcome(
              collection: 'items', status: SyncOutcomeStatus.alreadyApplied),
          SyncOutcome(
              collection: 'rectangles', status: SyncOutcomeStatus.superseded),
          SyncOutcome(
              collection: 'default_prices', status: SyncOutcomeStatus.rejected),
          SyncOutcome(
              collection: 'warranties',
              status: SyncOutcomeStatus.permanentlyDeleted),
          SyncOutcome(
              collection: 'proposals', status: SyncOutcomeStatus.unauthorized),
        ],
      );

      await provider.sync();

      expect(provider.viewState.kind, SyncViewKind.needsAttention);
      expect(
        provider.viewState.notices.map((notice) => notice.code).toSet(),
        {
          'applied',
          'already_applied',
          'superseded',
          'rejected',
          'permanently_deleted',
          'unauthorized',
        },
      );
      final persisted = await db.getSyncRecoveryState(_tenant);
      expect(
        provider.viewState.lastSuccessfulAt,
        DateTime.parse(persisted['last_successful_at'] as String).toUtc(),
      );
    });

    test(
        'is single-flight and reconnect remains manual after a transport failure',
        () async {
      service.gate = Completer<void>();
      final first = provider.sync();
      await _waitForStart(service);
      final repeated = provider.sync();
      expect(identical(first, repeated), isTrue);
      expect(service.calls, 1);
      service.gate!.complete();
      await first;

      service.failure = const SocketException('offline');
      await provider.sync();
      expect(provider.viewState.recoveryAction, SyncRecoveryAction.retry);
      final beforeRefresh = service.calls;
      connectionMonitor.emit(false);
      connectionMonitor.emit(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        provider.viewState.notices.single.code,
        'connection_restored',
      );
      expect(provider.viewState.recoveryAction, SyncRecoveryAction.retry);
      expect(service.calls, beforeRefresh,
          reason: 'restoration only displays a manual retry prompt');
      await provider.refresh();
      expect(service.calls, beforeRefresh,
          reason: 'reconnect/refresh never uploads automatically');
      service.failure = null;
      await provider.sync();
      expect(service.calls, beforeRefresh + 1);
    });

    test('maps typed errors without advancing a prior successful timestamp',
        () async {
      await provider.sync();
      final previous = provider.viewState.lastSuccessfulAt;
      final cases = <Object, SyncRecoveryAction>{
        const ApiException('expired', statusCode: 401):
            SyncRecoveryAction.signInAgain,
        const ApiException('forbidden', statusCode: 403):
            SyncRecoveryAction.contactAdministrator,
        const ApiException('review', statusCode: 422):
            SyncRecoveryAction.reviewRecord,
        const ApiException('conflict',
            statusCode: 409,
            code: 'idempotency_conflict'): SyncRecoveryAction.restorePhoto,
        const ApiException('deleted',
            statusCode: 410,
            code: 'uploaded_asset_deleted'): SyncRecoveryAction.restorePhoto,
        TimeoutException('timeout'): SyncRecoveryAction.retry,
        const ApiException('upgrade', statusCode: 426):
            SyncRecoveryAction.updateRequired,
      };
      for (final entry in cases.entries) {
        service.failure = entry.key;
        await provider.sync();
        expect(provider.viewState.recoveryAction, entry.value);
        expect(provider.viewState.lastSuccessfulAt, previous);
      }
    });

    test('does not retry a required update and fences sign-in-again logout',
        () async {
      var logoutCalls = 0;
      provider.updateSession(
        _session,
        onAuthenticationExpired: () async => logoutCalls += 1,
      );
      service.failure = const ApiException('expired', statusCode: 401);
      await provider.sync();
      expect(logoutCalls, 0, reason: 'logout is an explicit accessible action');
      await provider.performRecoveryAction(SyncRecoveryAction.signInAgain);
      expect(logoutCalls, 1);

      service.failure = const ApiException('upgrade', statusCode: 426);
      await provider.sync();
      final callsBeforeBlockedRetry = service.calls;
      await provider.sync();
      expect(service.calls, callsBeforeBlockedRetry);
    });

    test('replaces resolved notices before hydrate and keeps tenants isolated',
        () async {
      service.result = const SyncRunResult(
        outcomes: [
          SyncOutcome(
              collection: 'clients', status: SyncOutcomeStatus.rejected),
        ],
      );
      await provider.sync();
      service.result = const SyncRunResult(
        outcomes: [
          SyncOutcome(collection: 'clients', status: SyncOutcomeStatus.applied),
        ],
      );
      await provider.sync();
      await db.recordSyncRecoveryForSession(
        'tenant-b',
        notices: const [
          {'code': 'unauthorized', 'collection': 'clients'},
        ],
        isSessionCurrent: () => true,
      );

      final recreatedMonitor = _TestConnectionMonitor();
      final recreated = SyncProvider(
        syncService: service,
        connectionMonitor: recreatedMonitor,
      )..updateSession(_session);
      addTearDown(() async {
        recreated.dispose();
        await recreatedMonitor.close();
      });
      await recreated.refresh();
      expect(recreated.viewState.recoveryAction, SyncRecoveryAction.none);
      expect(
        recreated.viewState.notices.map((notice) => notice.code),
        ['applied'],
      );
      expect(
        (await db.getSyncRecoveryState('tenant-b'))['notices'],
        isNotEmpty,
      );
    });

    test(
        'logout during every reported phase leaves no stale success, notice, or provider state',
        () async {
      for (final phase in SyncPhase.values) {
        final phaseService = _ScriptedSyncService(db)
          ..phases = [phase]
          ..gate = Completer<void>();
        final phaseMonitor = _TestConnectionMonitor();
        final phaseProvider = SyncProvider(
          syncService: phaseService,
          connectionMonitor: phaseMonitor,
        )..updateSession(_session);
        final run = phaseProvider.sync();
        await _waitForStart(phaseService);
        phaseProvider.updateSession(null);
        phaseService.gate!.complete();
        await run;
        expect(phaseProvider.viewState, isA<SyncViewState>());
        expect(phaseProvider.viewState.lastSuccessfulAt, isNull);
        expect(phaseProvider.viewState.notices, isEmpty);
        phaseProvider.dispose();
        await phaseMonitor.close();
      }
      final state = await db.getSyncRecoveryState(_tenant);
      expect(state['last_successful_at'], isNull);
    });
  });

  group('APP-112 provider storage failures', () {
    late _FaultingStatusStore statusStore;
    late _ScriptedSyncService service;
    late _TestConnectionMonitor connectionMonitor;
    late SyncProvider provider;

    setUp(() async {
      statusStore = _FaultingStatusStore();
      connectionMonitor = _TestConnectionMonitor();
      service = _ScriptedSyncService(DbService());
      provider = SyncProvider(
        syncService: service,
        connectionMonitor: connectionMonitor,
        statusStore: statusStore,
      )..updateSession(_session);
      await provider.refresh();
    });

    tearDown(() async {
      provider.dispose();
      await connectionMonitor.close();
    });

    void expectSettledLocalStorage() {
      expect(provider.viewState.isRunning, isFalse);
      expect(provider.viewState.kind, SyncViewKind.needsAttention);
      expect(provider.viewState.notices.single.code, 'local_storage');
      expect(
          provider.viewState.recoveryAction, SyncRecoveryAction.restorePhoto);
    }

    test('settles after an attempt-write failure', () async {
      statusStore.failAttempt = true;

      await provider.sync();

      expectSettledLocalStorage();
      expect(service.calls, 0);
    });

    test('settles after a recovery-write failure', () async {
      service.failure = const SocketException('offline');
      statusStore.failRecovery = true;

      await provider.sync();

      expectSettledLocalStorage();
      expect(service.calls, 1);
    });

    test('settles after a count-read failure', () async {
      statusStore.failCounts = true;

      await provider.sync();

      expectSettledLocalStorage();
      expect(service.calls, 1);
    });
  });

  testWidgets(
    'APP-112 status and recovery UI uses labels, text, focusable action, and non-colour indicators',
    (tester) async {
      final connectionMonitor = _TestConnectionMonitor();
      final provider = _StaticSyncProvider(
        const SyncViewState(
          kind: SyncViewKind.needsAttention,
          notices: [SyncNotice(code: 'rejected', collection: 'clients')],
          recoveryAction: SyncRecoveryAction.reviewRecord,
        ),
        connectionMonitor: connectionMonitor,
      );
      addTearDown(() async {
        provider.dispose();
        await connectionMonitor.close();
      });
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<SyncProvider>.value(
            value: provider,
            child: const MaterialApp(home: SyncScreen()),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Sync needs attention'), findsOneWidget);
        expect(find.text('A change needs review before it can be synced.'),
            findsOneWidget);
        expect(find.text('Review affected records'), findsOneWidget);
        expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Sync needs attention')),
            findsWidgets);
        expect(
          find.bySemanticsLabel(
            RegExp('A change needs review before it can be synced'),
          ),
          findsWidgets,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'required update blocks Sync now and exposes accessible guidance without a request',
    (tester) async {
      final connectionMonitor = _TestConnectionMonitor();
      final provider = _StaticSyncProvider(
        const SyncViewState(
          kind: SyncViewKind.needsAttention,
          notices: [SyncNotice(code: 'required_update')],
          recoveryAction: SyncRecoveryAction.updateRequired,
        ),
        connectionMonitor: connectionMonitor,
      );
      addTearDown(() async {
        provider.dispose();
        await connectionMonitor.close();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<SyncProvider>.value(
          value: provider,
          child: const MaterialApp(home: SyncScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sync blocked until update'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(find.text('View update guidance'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('required update guidance')),
        findsWidgets,
      );

      await tester.tap(find.text('View update guidance'));
      await tester.pumpAndSettle();
      expect(find.text('Update required'), findsOneWidget);
    },
  );

  testWidgets(
    'forbidden sync exposes a contact-admin action without retrying',
    (tester) async {
      final connectionMonitor = _TestConnectionMonitor();
      final provider = _StaticSyncProvider(
        const SyncViewState(
          kind: SyncViewKind.needsAttention,
          notices: [SyncNotice(code: 'authorization')],
          recoveryAction: SyncRecoveryAction.contactAdministrator,
        ),
        connectionMonitor: connectionMonitor,
      );
      addTearDown(() async {
        provider.dispose();
        await connectionMonitor.close();
      });

      await tester.pumpWidget(
        ChangeNotifierProvider<SyncProvider>.value(
          value: provider,
          child: const MaterialApp(home: SyncScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Contact administrator'), findsOneWidget);
      await tester.tap(find.text('Contact administrator'));
      await tester.pumpAndSettle();
      expect(find.text('Contact administrator'), findsNWidgets(2));
      expect(find.textContaining('not authorised to sync'), findsNWidgets(2));
    },
  );
}
