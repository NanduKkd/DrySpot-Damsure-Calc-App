import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/client_form_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/warranty.dart';

class MockClientProvider extends ChangeNotifier implements ClientProvider {
  Client? addedClient;

  @override
  Future<void> addClient(Client client) async {
    addedClient = client;
    notifyListeners();
  }

  @override
  Future<void> updateClient(Client client) async {
    addedClient = client;
    notifyListeners();
  }

  @override
  List<Client> get clients => [];
  @override
  bool get isLoading => false;
  @override
  Future<void> loadClients() async {}
  @override
  Future<void> deleteClient(int localId) async {}
  @override
  Future<Item?> getItemByLocalId(int localId) async => null;
  @override
  Future<void> addRectangle(Rectangle rectangle) async {}
  @override
  Future<void> updateRectangle(Rectangle rectangle) async {}
  @override
  Future<void> deleteRectangle(int localId) async {}
  @override
  Future<void> updateItem(Item item) async {}
  @override
  Future<int> addItem(Item item) async => 0;
  @override
  Future<void> deleteItem(int localId) async {}
  @override
  Future<void> applyBulkPrice(int clientLocalId, double price) async {}
  @override
  List<Warranty> get currentClientWarranties => [];
  @override
  List<Proposal> get currentClientProposals => [];
  @override
  Future<void> loadWarranties(int clientLocalId) async {}
  @override
  Future<void> loadProposals(int clientLocalId) async {}
  @override
  Future<void> addWarranty(Warranty warranty) async {}
  @override
  Future<void> addProposal(Proposal proposal) async {}
  @override
  Future<void> deleteWarranty(int localId, int clientLocalId) async {}
  @override
  Future<void> deleteProposal(int localId, int clientLocalId) async {}
}

class MockAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  ApiService get apiService => throw UnimplementedError();
  @override
  String? get franchiseeId => 'f1-id';
  @override
  String? get userName => 'User';
  @override
  String? get franchiseeName => null;

  @override
  bool get isAuthenticated => true;
  @override
  Future<void> login(String email, String password) async {}
  @override
  Future<void> logout() async {}
  @override
  Future<void> tryAutoLogin() async {}
}

void main() {
  testWidgets('ClientFormScreen shows phone field and saves it',
      (WidgetTester tester) async {
    final mockClientProvider = MockClientProvider();
    final mockAuthProvider = MockAuthProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(
              value: mockClientProvider),
          ChangeNotifierProvider<AuthProvider>.value(value: mockAuthProvider),
        ],
        child: const MaterialApp(
          home: ClientFormScreen(),
        ),
      ),
    );

    // Verify Phone field exists
    final phoneFieldFinder = find.widgetWithText(TextFormField, 'Phone Number');
    expect(phoneFieldFinder, findsOneWidget);

    // Enter details
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Client Name *'), 'John Doe');
    await tester.enterText(phoneFieldFinder, '9998887776');

    // Tap Save
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    // Verify client was added with phone
    expect(mockClientProvider.addedClient, isNotNull);
    expect(mockClientProvider.addedClient!.name, 'John Doe');
    expect(mockClientProvider.addedClient!.phone, '9998887776');
  });
}
