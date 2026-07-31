import 'dart:async';

import 'package:flutter/material.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/warranty.dart';
import '../models/proposal.dart';
import '../services/db_service.dart';
import '../services/session_manager.dart';

class ClientProvider extends ChangeNotifier {
  ClientProvider({DbService? dbService, SessionManager? sessionManager})
      : _dbService = dbService ?? DbService(),
        _sessionManager = sessionManager {
    _sessionManager?.addInvalidationListener(_clearForInvalidation);
  }

  final DbService _dbService;
  final SessionManager? _sessionManager;
  List<Client> _clients = [];
  bool _isLoading = false;
  bool _sessionBound = false;
  SessionSnapshot? _session;
  int _sessionGeneration = 0;

  List<Warranty> _currentClientWarranties = [];
  List<Proposal> _currentClientProposals = [];

  List<Client> get clients => _clients;
  bool get isLoading => _isLoading;

  List<Warranty> get currentClientWarranties => _currentClientWarranties;
  List<Proposal> get currentClientProposals => _currentClientProposals;

  bool _isCurrent(SessionSnapshot? session) =>
      !_sessionBound ||
      (session != null &&
          _session?.generation == session.generation &&
          (_sessionManager == null || _sessionManager.isCurrent(session)));

  Future<bool> _ownsClient(int? localId, SessionSnapshot? session) async {
    if (!_sessionBound) return true;
    return localId != null &&
        session != null &&
        await _dbService.ownsClient(localId, session.franchiseeId);
  }

  Future<bool> _ownsItem(int? localId, SessionSnapshot? session) async {
    if (!_sessionBound) return true;
    return localId != null &&
        session != null &&
        await _dbService.ownsItem(localId, session.franchiseeId);
  }

  Future<bool> _ownsRectangle(int? localId, SessionSnapshot? session) async {
    if (!_sessionBound) return true;
    return localId != null &&
        session != null &&
        await _dbService.ownsRectangle(localId, session.franchiseeId);
  }

  void updateSession({
    required bool isAuthenticated,
    String? franchiseeId,
  }) {
    final normalizedFranchiseeId =
        franchiseeId?.trim().isNotEmpty == true ? franchiseeId!.trim() : null;
    final sharedSession = _sessionManager?.current;
    final nextSession = isAuthenticated && normalizedFranchiseeId != null
        ? (sharedSession?.franchiseeId == normalizedFranchiseeId
            ? sharedSession
            : (_session?.franchiseeId == normalizedFranchiseeId
                ? _session
                : SessionSnapshot(
                    token: 'provider-session',
                    userName: null,
                    franchiseeId: normalizedFranchiseeId,
                    franchiseeName: null,
                    generation: ++_sessionGeneration,
                  )))
        : null;
    _applySession(nextSession);
  }

  void _applySession(SessionSnapshot? nextSession) {
    final hasChanged = !_sessionBound ||
        _session?.generation != nextSession?.generation ||
        _session?.franchiseeId != nextSession?.franchiseeId;

    if (!hasChanged) {
      return;
    }

    _sessionBound = true;
    _session = nextSession;

    // A session transition clears every visible value synchronously, before
    // the new tenant's asynchronous SQLite read can begin.
    _clients = [];
    _currentClientWarranties = [];
    _currentClientProposals = [];
    _isLoading = false;
    notifyListeners();

    if (nextSession != null) unawaited(loadClients());
  }

  void _clearForInvalidation() {
    _sessionBound = true;
    _session = null;
    _clients = [];
    _currentClientWarranties = [];
    _currentClientProposals = [];
    _isLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionManager?.removeInvalidationListener(_clearForInvalidation);
    super.dispose();
  }

  Future<void> loadClients() async {
    final session = _session;
    if (session == null && _sessionBound) return;
    _isLoading = true;
    notifyListeners();

    final clients = session == null
        ? await _dbService.getClients()
        : await _dbService.getClientsForFranchisee(session.franchiseeId);
    if (!_isCurrent(session)) {
      return;
    }
    _clients = clients;

    _isLoading = false;
    notifyListeners();
  }

  Future<void> addClient(Client client) async {
    final session = _session;
    if (_sessionBound &&
        (session == null ||
            !_isCurrent(session) ||
            client.franchiseeId != session.franchiseeId)) {
      return;
    }
    if (session == null) {
      await _dbService.insertClient(client);
    } else {
      await _dbService.writeForSession(
        table: 'clients',
        values: client.toMap(),
        insert: true,
        markLocalLwwCollection: client.isDirty ? 'clients' : null,
        useInsertedIdForLocalLww: client.isDirty,
        syncPendingPhotosForInsertedId: true,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> updateClient(Client client) async {
    final session = _session;
    if (client.franchiseeId != null &&
        client.franchiseeId != session?.franchiseeId) {
      return;
    }
    if (!await _ownsClient(client.localId, session) || !_isCurrent(session)) {
      return;
    }
    final updated = client.copyWith(isDirty: true, updatedAt: DateTime.now());
    if (session == null) {
      await _dbService.updateClient(updated);
    } else {
      await _dbService.writeForSession(
        table: 'clients',
        values: updated.toMap(),
        where: 'local_id = ? AND franchisee_id = ?',
        whereArgs: [updated.localId, session.franchiseeId],
        markLocalLwwCollection: 'clients',
        markLocalLwwId: updated.localId,
        syncPendingClientPhotosId: updated.localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteClient(int localId) async {
    final session = _session;
    if (!await _ownsClient(localId, session) || !_isCurrent(session)) return;
    if (session == null) {
      await _dbService.softDeleteClient(localId);
    } else {
      await _dbService.softDeleteClientForSession(
        localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<int> addItem(Item item) async {
    final session = _session;
    if (!await _ownsClient(item.clientId, session) || !_isCurrent(session)) {
      return 0;
    }
    final id = session == null
        ? await _dbService.insertItem(item)
        : await _dbService.writeForSession(
            table: 'items',
            values: item.toMap(),
            insert: true,
            markLocalLwwCollection: item.isDirty ? 'items' : null,
            useInsertedIdForLocalLww: item.isDirty,
            isSessionCurrent: () => _isCurrent(session),
          );
    if (!_isCurrent(session)) return 0;
    await loadClients();
    return id;
  }

  Future<Item?> getItemByLocalId(int localId) async {
    final session = _session;
    if (_sessionBound && session == null) return null;
    final item = session == null
        ? await _dbService.getItemByLocalId(localId)
        : await _dbService.getItemByLocalIdForFranchisee(
            localId,
            session.franchiseeId,
          );
    return _isCurrent(session) ? item : null;
  }

  Future<void> updateItem(Item item) async {
    final session = _session;
    if (!await _ownsItem(item.localId, session) || !_isCurrent(session)) return;
    final updated = item.copyWith(isDirty: true, updatedAt: DateTime.now());
    if (session == null) {
      await _dbService.updateItem(updated);
    } else {
      await _dbService.writeForSession(
        table: 'items',
        values: updated.toMap(),
        where: 'local_id = ?',
        whereArgs: [updated.localId],
        markLocalLwwCollection: 'items',
        markLocalLwwId: updated.localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteItem(int localId) async {
    final session = _session;
    if (!await _ownsItem(localId, session) || !_isCurrent(session)) return;
    if (session == null) {
      await _dbService.softDeleteItem(localId);
    } else {
      await _dbService.writeForSession(
        table: 'items',
        values: {
          'deleted_at': DateTime.now().toIso8601String(),
          'is_dirty': 1,
        },
        where: 'local_id = ?',
        whereArgs: [localId],
        markLocalLwwCollection: 'items',
        markLocalLwwId: localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> addRectangle(Rectangle rectangle) async {
    final session = _session;
    if (!await _ownsItem(rectangle.itemId, session) || !_isCurrent(session)) {
      return;
    }
    if (session == null) {
      await _dbService.insertRectangle(rectangle);
    } else {
      await _dbService.writeForSession(
        table: 'rectangles',
        values: rectangle.toMap(),
        insert: true,
        markLocalLwwCollection: rectangle.isDirty ? 'rectangles' : null,
        useInsertedIdForLocalLww: rectangle.isDirty,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> updateRectangle(Rectangle rectangle) async {
    final session = _session;
    if (!await _ownsRectangle(rectangle.localId, session) ||
        !_isCurrent(session)) {
      return;
    }
    final updated = rectangle.copyWith(
      isDirty: true,
      updatedAt: DateTime.now(),
    );
    if (session == null) {
      await _dbService.updateRectangle(updated);
    } else {
      await _dbService.writeForSession(
        table: 'rectangles',
        values: updated.toMap(),
        where: 'local_id = ?',
        whereArgs: [updated.localId],
        markLocalLwwCollection: 'rectangles',
        markLocalLwwId: updated.localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteRectangle(int localId) async {
    final session = _session;
    if (!await _ownsRectangle(localId, session) || !_isCurrent(session)) {
      return;
    }
    if (session == null) {
      await _dbService.softDeleteRectangle(localId);
    } else {
      await _dbService.writeForSession(
        table: 'rectangles',
        values: {
          'deleted_at': DateTime.now().toIso8601String(),
          'is_dirty': 1,
        },
        where: 'local_id = ? AND deleted_at IS NULL',
        whereArgs: [localId],
        markLocalLwwCollection: 'rectangles',
        markLocalLwwId: localId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> applyBulkPrice(int clientLocalId, double price) async {
    final session = _session;
    if (!await _ownsClient(clientLocalId, session) || !_isCurrent(session)) {
      return;
    }
    final client = _clients.firstWhere((c) => c.localId == clientLocalId);
    for (var item in client.items) {
      if (!_isCurrent(session)) return;
      final updated = item.copyWith(
        price: price,
        isDirty: true,
        updatedAt: DateTime.now(),
      );
      if (session == null) {
        await _dbService.updateItem(updated);
      } else {
        await _dbService.writeForSession(
          table: 'items',
          values: updated.toMap(),
          where: 'local_id = ?',
          whereArgs: [updated.localId],
          markLocalLwwCollection: 'items',
          markLocalLwwId: updated.localId,
          isSessionCurrent: () => _isCurrent(session),
        );
      }
    }
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> loadWarranties(int clientLocalId) async {
    final session = _session;
    if (session == null) return;
    final warranties = await _dbService.getWarrantiesByClientIdForFranchisee(
      clientLocalId,
      session.franchiseeId,
    );
    if (!_isCurrent(session)) return;
    _currentClientWarranties = warranties;
    notifyListeners();
  }

  Future<void> loadProposals(int clientLocalId) async {
    final session = _session;
    if (session == null) return;
    final proposals = await _dbService.getProposalsByClientIdForFranchisee(
      clientLocalId,
      session.franchiseeId,
    );
    if (!_isCurrent(session)) return;
    _currentClientProposals = proposals;
    notifyListeners();
  }

  Future<void> addWarranty(Warranty warranty) async {
    final session = _session;
    if (!await _ownsClient(warranty.clientId, session) ||
        !_isCurrent(session)) {
      return;
    }
    // The server has already committed either creation or atomic replacement.
    // Mirror that result locally without creating a dirty offline delete.
    if (session == null) {
      await _dbService.replaceWarrantyFromServer(warranty);
    } else {
      await _dbService.replaceWarrantyFromServerForSession(
        warranty,
        franchiseeId: session.franchiseeId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadWarranties(warranty.clientId);
  }

  Future<void> addProposal(Proposal proposal) async {
    final session = _session;
    if (!await _ownsClient(proposal.clientId, session) ||
        !_isCurrent(session)) {
      return;
    }
    if (session == null) {
      await _dbService.insertProposal(proposal);
    } else {
      await _dbService.writeForSession(
        table: 'proposals',
        values: proposal.toMap(),
        insert: true,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadProposals(proposal.clientId);
  }

  Future<void> deleteWarranty(int localId, int clientLocalId) async {
    final session = _session;
    if (!await _ownsClient(clientLocalId, session) || !_isCurrent(session)) {
      return;
    }
    // Permanent warranty deletion is online/server-authoritative. This method
    // is called only after the confirmed API request succeeds.
    if (session == null) {
      await _dbService.hardDeleteWarranty(localId);
    } else {
      await _dbService.writeForSession(
        table: 'warranties',
        values: const {},
        delete: true,
        where: 'local_id = ? AND client_id = ?',
        whereArgs: [localId, clientLocalId],
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadWarranties(clientLocalId);
  }

  Future<void> deleteProposal(int localId, int clientLocalId) async {
    final session = _session;
    if (!await _ownsClient(clientLocalId, session) || !_isCurrent(session)) {
      return;
    }
    if (session == null) {
      await _dbService.softDeleteProposal(localId);
    } else {
      await _dbService.writeForSession(
        table: 'proposals',
        values: {
          'deleted_at': DateTime.now().toIso8601String(),
          'is_dirty': 1,
        },
        where: 'local_id = ? AND client_id = ?',
        whereArgs: [localId, clientLocalId],
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    await loadProposals(clientLocalId);
  }
}
