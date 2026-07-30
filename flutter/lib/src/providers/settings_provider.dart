import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/default_price.dart';
import '../services/db_service.dart';

class SettingsProvider with ChangeNotifier {
  SettingsProvider({DbService? dbService})
      : _dbService = dbService ?? DbService();

  final DbService _dbService;
  List<DefaultPrice> _defaultPrices = [];
  bool _sessionBound = false;
  String? _franchiseeId;

  List<DefaultPrice> get defaultPrices => _defaultPrices;

  Future<String?> _activeFranchiseeId() async {
    if (_sessionBound) return _franchiseeId;
    final id = (await SharedPreferences.getInstance())
        .getString('franchisee_id')
        ?.trim();
    return id == null || id.isEmpty ? null : id;
  }

  Future<void> loadSettings() async {
    final franchiseeId = await _activeFranchiseeId();
    await _loadForFranchisee(franchiseeId);
  }

  void updateSession({
    required bool isAuthenticated,
    String? franchiseeId,
  }) {
    final normalizedFranchiseeId =
        franchiseeId?.trim().isNotEmpty == true ? franchiseeId!.trim() : null;
    final nextFranchiseeId = isAuthenticated ? normalizedFranchiseeId : null;
    if (_sessionBound && _franchiseeId == nextFranchiseeId) return;

    _sessionBound = true;
    _franchiseeId = nextFranchiseeId;
    _defaultPrices = [];
    notifyListeners();
    if (nextFranchiseeId != null) {
      unawaited(_loadForFranchisee(nextFranchiseeId));
    }
  }

  Future<void> _loadForFranchisee(String? franchiseeId) async {
    if (franchiseeId != null) {
      // Version 7 and earlier stored one device-wide price table. The first
      // authenticated tenant after upgrade claims those otherwise orphaned
      // rows; subsequent tenants cannot see or reclaim them.
      await _dbService.claimLegacyDefaultPrices(franchiseeId);
    }
    final prices = franchiseeId == null
        ? <DefaultPrice>[]
        : await _dbService.getDefaultPrices(franchiseeId);
    if (_sessionBound && _franchiseeId != franchiseeId) return;
    _defaultPrices = prices;
    notifyListeners();
  }

  Future<void> addDefaultPrice(double price) async {
    final franchiseeId = await _activeFranchiseeId();
    if (franchiseeId == null) return;
    final newPrice = DefaultPrice.createNew(
      franchiseeId: franchiseeId,
      price: price,
    );
    await _dbService.insertDefaultPrice(newPrice, franchiseeId: franchiseeId);
    await loadSettings();
  }

  Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {
    final franchiseeId = await _activeFranchiseeId();
    if (franchiseeId == null || defaultPrice.franchiseeId != franchiseeId) {
      return;
    }
    await _dbService.updateDefaultPrice(
      defaultPrice.copyWith(updatedAt: DateTime.now(), isDirty: true),
      franchiseeId: franchiseeId,
    );
    await loadSettings();
  }

  Future<void> deleteDefaultPrice(int localId) async {
    final franchiseeId = await _activeFranchiseeId();
    if (franchiseeId == null) return;
    await _dbService.deleteDefaultPrice(localId, franchiseeId: franchiseeId);
    await loadSettings();
  }

  double get firstDefaultPrice {
    if (_defaultPrices.isEmpty) return 0.0;
    return _defaultPrices
        .firstWhere((p) => p.enabled, orElse: () => _defaultPrices.first)
        .price;
  }
}
