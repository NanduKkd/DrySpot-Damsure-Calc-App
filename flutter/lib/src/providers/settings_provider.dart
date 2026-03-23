import 'package:flutter/material.dart';
import '../models/default_price.dart';
import '../services/db_service.dart';

class SettingsProvider with ChangeNotifier {
  final DbService _dbService = DbService();
  List<DefaultPrice> _defaultPrices = [];

  List<DefaultPrice> get defaultPrices => _defaultPrices;

  Future<void> loadSettings() async {
    _defaultPrices = await _dbService.getDefaultPrices();
    notifyListeners();
  }

  Future<void> addDefaultPrice(double price) async {
    final newPrice = DefaultPrice.createNew(price: price);
    await _dbService.insertDefaultPrice(newPrice);
    await loadSettings();
  }

  Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {
    await _dbService.updateDefaultPrice(defaultPrice.copyWith(updatedAt: DateTime.now()));
    await loadSettings();
  }

  Future<void> deleteDefaultPrice(int localId) async {
    await _dbService.deleteDefaultPrice(localId);
    await loadSettings();
  }

  double get firstDefaultPrice {
    if (_defaultPrices.isEmpty) return 0.0;
    return _defaultPrices.firstWhere((p) => p.enabled, orElse: () => _defaultPrices.first).price;
  }
}
