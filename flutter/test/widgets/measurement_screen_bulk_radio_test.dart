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

class MockClientProvider extends ChangeNotifier implements ClientProvider {
  double? appliedPrice;
  final Client _client;
  MockClientProvider(this._client);

  @override
  List<Client> get clients => [_client];

  @override
  Future<void> applyBulkPrice(int clientLocalId, double price) async {
    appliedPrice = price;
    notifyListeners();
  }

  // Other stubs
  @override bool get isLoading => false;
  @override Future<void> loadClients() async {}
  @override Future<void> addClient(Client client) async {}
  @override Future<void> updateClient(Client client) async {}
  @override Future<void> deleteClient(int localId) async {}
  @override Future<int> addItem(Item item) async => 0;
  @override Future<Item?> getItemByLocalId(int localId) async => null;
  @override Future<void> updateItem(Item item) async {}
  @override Future<void> deleteItem(int localId) async {}
  @override Future<void> addRectangle(Rectangle rectangle) async {}
  @override Future<void> updateRectangle(Rectangle rectangle) async {}
  @override Future<void> deleteRectangle(int localId) async {}
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
  testWidgets('MeasurementScreen bulk apply shows radio buttons', (WidgetTester tester) async {
    final client = Client(name: 'Test Client', localId: 1, items: []);
    final mockClientProvider = MockClientProvider(client);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockClientProvider),
          ChangeNotifierProvider<SettingsProvider>.value(value: mockSettingsProvider),
        ],
        child: MaterialApp(
          home: MeasurementScreen(client: client),
        ),
      ),
    );

    // Tap bulk apply icon (should have a tooltip or icon)
    // In my code, it's an IconButton with icon: Icons.price_check
    await tester.tap(find.byIcon(Icons.price_check));
    await tester.pumpAndSettle();

    // Verify radio buttons
    expect(find.textContaining('45'), findsOneWidget);
    expect(find.textContaining('50'), findsOneWidget);
    expect(find.textContaining('60'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    // Select 60.0 and Apply
    await tester.tap(find.textContaining('60'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(mockClientProvider.appliedPrice, 60.0);
  });
}
