import 'dart:async';

import 'package:flutter/material.dart';
import '../models/default_price.dart';
import '../services/db_service.dart';
import '../services/session_manager.dart';

class SettingsProvider with ChangeNotifier {
  SettingsProvider({DbService? dbService, SessionManager? sessionManager})
      : _dbService = dbService ?? DbService(),
        _sessionManager = sessionManager {
    _sessionManager?.addInvalidationListener(_clearForInvalidation);
  }

  final DbService _dbService;
  final SessionManager? _sessionManager;
  List<DefaultPrice> _defaultPrices = [];
  bool _sessionBound = false;
  SessionSnapshot? _session;
  int _compatGeneration = 0;

  List<DefaultPrice> get defaultPrices => _defaultPrices;

  String? get _activeFranchiseeId => _session?.franchiseeId;

  bool _isCurrent(SessionSnapshot? session) =>
      session != null &&
      _session?.generation == session.generation &&
      (_sessionManager == null || _sessionManager.isCurrent(session));

  Future<void> loadSettings() async {
    final session = _session;
    if (session == null) return;
    await _loadForSession(session);
  }

  void updateSession({
    required bool isAuthenticated,
    String? franchiseeId,
  }) {
    final normalizedFranchiseeId = franchiseeId?.trim();
    final sharedSession = _sessionManager?.current;
    final nextSession = isAuthenticated
        ? (sharedSession?.franchiseeId == normalizedFranchiseeId
            ? sharedSession
            : (_session?.franchiseeId == normalizedFranchiseeId
                ? _session
                : (normalizedFranchiseeId == null ||
                        normalizedFranchiseeId.isEmpty
                    ? null
                    : SessionSnapshot(
                        token: 'provider-session',
                        userName: null,
                        franchiseeId: normalizedFranchiseeId,
                        franchiseeName: null,
                        generation: ++_compatGeneration,
                      ))))
        : null;
    _applySession(nextSession);
  }

  void _applySession(SessionSnapshot? nextSession) {
    if (_sessionBound && _session?.generation == nextSession?.generation) {
      return;
    }

    _sessionBound = true;
    _session = nextSession;
    _defaultPrices = [];
    notifyListeners();
    if (nextSession != null) {
      unawaited(_loadForSession(nextSession));
    }
  }

  void _clearForInvalidation() {
    _sessionBound = true;
    _session = null;
    _defaultPrices = [];
    notifyListeners();
  }

  @override
  void dispose() {
    _sessionManager?.removeInvalidationListener(_clearForInvalidation);
    super.dispose();
  }

  Future<void> _loadForSession(SessionSnapshot session) async {
    final franchiseeId = session.franchiseeId;
    if (!_isCurrent(session)) return;
    {
      // Version 7 and earlier stored one device-wide price table. The first
      // authenticated tenant after upgrade claims those otherwise orphaned
      // rows; subsequent tenants cannot see or reclaim them.
      await _dbService.claimLegacyDefaultPricesForSession(
        franchiseeId,
        isSessionCurrent: () => _isCurrent(session),
      );
    }
    if (!_isCurrent(session)) return;
    final prices = await _dbService.getDefaultPrices(franchiseeId);
    if (!_isCurrent(session)) return;
    _defaultPrices = prices;
    notifyListeners();
  }

  Future<void> addDefaultPrice(double price) async {
    final session = _session;
    final franchiseeId = _activeFranchiseeId;
    if (franchiseeId == null || !_isCurrent(session)) return;
    final newPrice = DefaultPrice.createNew(
      franchiseeId: franchiseeId,
      price: price,
    );
    await _dbService.insertDefaultPrice(newPrice, franchiseeId: franchiseeId);
    if (!_isCurrent(session)) return;
    await loadSettings();
  }

  Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {
    final session = _session;
    final franchiseeId = _activeFranchiseeId;
    if (franchiseeId == null ||
        !_isCurrent(session) ||
        defaultPrice.franchiseeId != franchiseeId) {
      return;
    }
    await _dbService.updateDefaultPrice(
      defaultPrice.copyWith(updatedAt: DateTime.now(), isDirty: true),
      franchiseeId: franchiseeId,
    );
    if (!_isCurrent(session)) return;
    await loadSettings();
  }

  Future<void> deleteDefaultPrice(int localId) async {
    final session = _session;
    final franchiseeId = _activeFranchiseeId;
    if (franchiseeId == null || !_isCurrent(session)) return;
    await _dbService.deleteDefaultPrice(localId, franchiseeId: franchiseeId);
    if (!_isCurrent(session)) return;
    await loadSettings();
  }

  double get firstDefaultPrice {
    if (_defaultPrices.isEmpty) return 0.0;
    return _defaultPrices
        .firstWhere((p) => p.enabled, orElse: () => _defaultPrices.first)
        .price;
  }
}
