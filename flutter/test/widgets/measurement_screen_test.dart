import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/measurement_screen.dart';
import 'package:app_client/src/screens/clients/item_detail_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/default_price.dart';

class MockClientProvider extends ClientProvider {
  final Client _client;
  MockClientProvider(this._client);

  @override
  List<Client> get clients => [_client];

  @override
  Future<int> addItem(Item item) async {
    // Return a dummy ID
    return 999;
  }

  @override
  Future<Item?> getItemByLocalId(int localId) async {
    return _client.items.firstWhere((i) => i.localId == localId);
  }
}

class MockSettingsProvider extends SettingsProvider {
  @override
  double get firstDefaultPrice => 12.5;

  @override
  Future<void> loadSettings() async {}

  @override
  List<DefaultPrice> get defaultPrices => [];
}

void main() {
  testWidgets('MeasurementScreen: Add Item dialog only has Name field', (WidgetTester tester) async {
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

    // Tap the button to add item
    await tester.tap(find.widgetWithText(ElevatedButton, 'Add Item'));
    await tester.pumpAndSettle();

    // The dialog should have "Add Item" as title
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('Add Item')), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Name (e.g., Roof)'), findsOneWidget);
    // Ensure Price field is NOT present
    expect(find.widgetWithText(TextField, 'Price'), findsNothing);
  });

  testWidgets('MeasurementScreen: Tapping an item navigates to ItemDetailScreen', (WidgetTester tester) async {
    final item = Item(name: 'Test Item', price: 10.0, localId: 101, clientId: 1);
    final client = Client(name: 'Test Client', localId: 1, items: [item]);
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

    await tester.tap(find.textContaining('Test Item'));
    await tester.pumpAndSettle();

    expect(find.byType(ItemDetailScreen), findsOneWidget);
  });
}
