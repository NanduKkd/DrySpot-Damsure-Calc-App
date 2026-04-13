import 'package:flutter/material.dart';
import '../models/client.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../models/warranty.dart';
import '../models/proposal.dart';
import '../services/db_service.dart';

class ClientProvider extends ChangeNotifier {
  final DbService _dbService = DbService();
  List<Client> _clients = [];
  bool _isLoading = false;

  List<Warranty> _currentClientWarranties = [];
  List<Proposal> _currentClientProposals = [];

  List<Client> get clients => _clients;
  bool get isLoading => _isLoading;

  List<Warranty> get currentClientWarranties => _currentClientWarranties;
  List<Proposal> get currentClientProposals => _currentClientProposals;

  Future<void> loadClients() async {
    _isLoading = true;
    notifyListeners();
    _clients = await _dbService.getClients();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> addClient(Client client) async {
    await _dbService.insertClient(client);
    await loadClients();
  }

  Future<void> updateClient(Client client) async {
    await _dbService.updateClient(client);
    await loadClients();
  }

  Future<void> deleteClient(int localId) async {
    await _dbService.softDeleteClient(localId);
    await loadClients();
  }

  Future<int> addItem(Item item) async {
    final id = await _dbService.insertItem(item);
    await loadClients();
    return id;
  }

  Future<Item?> getItemByLocalId(int localId) async {
    return await _dbService.getItemByLocalId(localId);
  }

  Future<void> updateItem(Item item) async {
    await _dbService.updateItem(item);
    await loadClients();
  }

  Future<void> deleteItem(int localId) async {
    await _dbService.softDeleteItem(localId);
    await loadClients();
  }

  Future<void> addRectangle(Rectangle rectangle) async {
    await _dbService.insertRectangle(rectangle);
    await loadClients();
  }

  Future<void> updateRectangle(Rectangle rectangle) async {
    await _dbService.updateRectangle(rectangle);
    await loadClients();
  }

  Future<void> deleteRectangle(int localId) async {
    await _dbService.softDeleteRectangle(localId);
    await loadClients();
  }

  Future<void> applyBulkPrice(int clientLocalId, double price) async {
    final client = _clients.firstWhere((c) => c.localId == clientLocalId);
    for (var item in client.items) {
      await _dbService.updateItem(item.copyWith(price: price, updatedAt: DateTime.now()));
    }
    await loadClients();
  }

  Future<void> loadWarranties(int clientLocalId) async {
    _currentClientWarranties =
        await _dbService.getWarrantiesByClientId(clientLocalId);
    notifyListeners();
  }

  Future<void> loadProposals(int clientLocalId) async {
    _currentClientProposals =
        await _dbService.getProposalsByClientId(clientLocalId);
    notifyListeners();
  }

  Future<void> addWarranty(Warranty warranty) async {
    await _dbService.insertWarranty(warranty);
    await loadWarranties(warranty.clientId);
  }

  Future<void> addProposal(Proposal proposal) async {
    await _dbService.insertProposal(proposal);
    await loadProposals(proposal.clientId);
  }

  Future<void> deleteWarranty(int localId, int clientLocalId) async {
    await _dbService.softDeleteWarranty(localId);
    await loadWarranties(clientLocalId);
  }

  Future<void> deleteProposal(int localId, int clientLocalId) async {
    await _dbService.softDeleteProposal(localId);
    await loadProposals(clientLocalId);
  }
}
