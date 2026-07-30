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
        _sessionManager = sessionManager;

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
    await _dbService.insertClient(client);
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
    await _dbService.updateClient(
      client.copyWith(isDirty: true, updatedAt: DateTime.now()),
    );
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteClient(int localId) async {
    final session = _session;
    if (!await _ownsClient(localId, session) || !_isCurrent(session)) return;
    await _dbService.softDeleteClient(localId);
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<int> addItem(Item item) async {
    final session = _session;
    if (!await _ownsClient(item.clientId, session) || !_isCurrent(session)) {
      return 0;
    }
    final id = await _dbService.insertItem(item);
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
    await _dbService.updateItem(
      item.copyWith(isDirty: true, updatedAt: DateTime.now()),
    );
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteItem(int localId) async {
    final session = _session;
    if (!await _ownsItem(localId, session) || !_isCurrent(session)) return;
    await _dbService.softDeleteItem(localId);
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> addRectangle(Rectangle rectangle) async {
    final session = _session;
    if (!await _ownsItem(rectangle.itemId, session) || !_isCurrent(session)) {
      return;
    }
    await _dbService.insertRectangle(rectangle);
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> updateRectangle(Rectangle rectangle) async {
    final session = _session;
    if (!await _ownsRectangle(rectangle.localId, session) ||
        !_isCurrent(session)) {
      return;
    }
    await _dbService.updateRectangle(
      rectangle.copyWith(isDirty: true, updatedAt: DateTime.now()),
    );
    if (!_isCurrent(session)) return;
    await loadClients();
  }

  Future<void> deleteRectangle(int localId) async {
    final session = _session;
    if (!await _ownsRectangle(localId, session) || !_isCurrent(session)) {
      return;
    }
    await _dbService.softDeleteRectangle(localId);
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
      await _dbService.updateItem(
        item.copyWith(price: price, isDirty: true, updatedAt: DateTime.now()),
      );
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
    await _dbService.replaceWarrantyFromServer(warranty);
    if (!_isCurrent(session)) return;
    await loadWarranties(warranty.clientId);
  }

  Future<void> addProposal(Proposal proposal) async {
    final session = _session;
    if (!await _ownsClient(proposal.clientId, session) ||
        !_isCurrent(session)) {
      return;
    }
    await _dbService.insertProposal(proposal);
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
    await _dbService.hardDeleteWarranty(localId);
    if (!_isCurrent(session)) return;
    await loadWarranties(clientLocalId);
  }

  Future<void> deleteProposal(int localId, int clientLocalId) async {
    final session = _session;
    if (!await _ownsClient(clientLocalId, session) || !_isCurrent(session)) {
      return;
    }
    await _dbService.softDeleteProposal(localId);
    if (!_isCurrent(session)) return;
    await loadProposals(clientLocalId);
  }
}
