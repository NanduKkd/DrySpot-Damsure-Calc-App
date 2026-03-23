import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/measurement_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/default_price.dart';
import 'package:app_client/src/services/api_service.dart';

class MockClientProvider extends ChangeNotifier implements ClientProvider {
  Client _client;
  MockClientProvider(this._client);

  @override List<Client> get clients => [_client];
  @override bool get isLoading => false;
  
  @override
  Future<void> updateClient(Client client) async {
    _client = client;
    notifyListeners();
  }

  @override Future<void> loadClients() async {}
  @override Future<void> addClient(Client client) async {}
  @override Future<void> deleteClient(int localId) async {}
  @override Future<int> addItem(Item item) async => 0;
  @override Future<Item?> getItemByLocalId(int localId) async => null;
  @override Future<void> updateItem(Item item) async {}
  @override Future<void> deleteItem(int localId) async {}
  @override Future<void> addRectangle(dynamic rectangle) async {}
  @override Future<void> updateRectangle(dynamic rectangle) async {}
  @override Future<void> deleteRectangle(int localId) async {}
  @override Future<void> applyBulkPrice(int clientLocalId, double price) async {}
}

class MockSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override List<DefaultPrice> get defaultPrices => [];
  @override Future<void> loadSettings() async {}
  @override double get firstDefaultPrice => 45.0;
  @override Future<void> addDefaultPrice(double price) async {}
  @override Future<void> updateDefaultPrice(dynamic defaultPrice) async {}
  @override Future<void> deleteDefaultPrice(int localId) async {}
}

class MockApiService extends Fake implements ApiService {}

void main() {
  testWidgets('MeasurementScreen discount dialog and display test', (WidgetTester tester) async {
    final item = Item(
      name: 'Test Item', 
      price: 10, 
      localId: 1,
      rectangles: [Rectangle(length: 10, width: 10)], // Area: 100
    );
    final client = Client(name: 'Test Client', localId: 1, items: [item]);

    final mockProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockProvider),
          ChangeNotifierProvider<SettingsProvider>.value(value: mockSettingsProvider),
          Provider<ApiService>(create: (_) => MockApiService()),
        ],
        child: MaterialApp(
          home: MeasurementScreen(client: client),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial total price is shown
    expect(find.text('Total Price: ₹1000.00'), findsOneWidget);

    // Verify "Discount" button
    final discountButtonFinder = find.text('Discount');
    expect(discountButtonFinder, findsOneWidget);
    
    await tester.tap(discountButtonFinder);
    await tester.pumpAndSettle();

    expect(find.text('Apply Discount'), findsOneWidget);
    expect(find.text('Original Total: ₹1000.00'), findsOneWidget);

    // Enter discounted price
    final priceField = find.widgetWithText(TextField, 'Discounted Price');
    await tester.enterText(priceField, '800.0');
    
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Verify updated UI
    expect(find.text('Original: ₹1000.00'), findsOneWidget);
    expect(find.text('Discounted: ₹800.00'), findsOneWidget);
  });
}
