import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/item_detail_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/default_price.dart';

class MockClientProvider extends ChangeNotifier implements ClientProvider {
  Item? updatedItem;
  final Item _item;
  MockClientProvider(this._item);

  @override
  Future<Item?> getItemByLocalId(int localId) async => _item;

  @override
  Future<void> updateItem(Item item) async {
    updatedItem = item;
    notifyListeners();
  }

  // Other stubs
  @override List<Client> get clients => [];
  @override bool get isLoading => false;
  @override Future<void> loadClients() async {}
  @override Future<void> addClient(Client client) async {}
  @override Future<void> updateClient(Client client) async {}
  @override Future<void> deleteClient(int localId) async {}
  @override Future<int> addItem(Item item) async => 0;
  @override Future<void> deleteItem(int localId) async {}
  @override Future<void> addRectangle(Rectangle rectangle) async {}
  @override Future<void> updateRectangle(Rectangle rectangle) async {}
  @override Future<void> deleteRectangle(int localId) async {}
  @override Future<void> applyBulkPrice(int clientLocalId, double price) async {}
}

class MockSettingsProvider extends ChangeNotifier implements SettingsProvider {
  final List<DefaultPrice> _defaultPrices = [
    DefaultPrice(localId: 1, price: 45.0, enabled: true, updatedAt: DateTime.now()),
    DefaultPrice(localId: 2, price: 50.0, enabled: true, updatedAt: DateTime.now()),
    DefaultPrice(localId: 3, price: 60.0, enabled: true, updatedAt: DateTime.now()),
  ];

  @override List<DefaultPrice> get defaultPrices => _defaultPrices;

  @override Future<void> loadSettings() async {}
  @override double get firstDefaultPrice => 45.0;
  @override Future<void> addDefaultPrice(double price) async {}
  @override Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {}
  @override Future<void> deleteDefaultPrice(int localId) async {}
}

void main() {
  testWidgets('ItemDetailScreen shows radio buttons for default prices', (WidgetTester tester) async {
    final item = Item(name: 'Test Item', price: 45.0, localId: 1);
    final mockClientProvider = MockClientProvider(item);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(value: mockSettingsProvider),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify radio buttons for default prices (e.g. 45.0, 50.0, 60.0)
    // The exact text depends on how it's implemented, e.g. "₹45.0"
    expect(find.textContaining('45'), findsAtLeast(1));
    expect(find.textContaining('50'), findsAtLeast(1));
    expect(find.textContaining('60'), findsAtLeast(1));
    expect(find.text('Custom'), findsOneWidget);

    // Select 50.0
    await tester.tap(find.textContaining('50'));
    await tester.pumpAndSettle();

    // Verify updateItem was called with new price
    expect(mockClientProvider.updatedItem?.price, 50.0);
  });
}
