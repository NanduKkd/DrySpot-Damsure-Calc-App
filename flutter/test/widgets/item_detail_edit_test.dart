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
  Item _item;
  MockClientProvider(this._item);

  @override
  Future<Item?> getItemByLocalId(int localId) async {
    return _item;
  }

  @override
  Future<void> addRectangle(Rectangle rectangle) async {
    _item = _item.copyWith(
      rectangles: [..._item.rectangles, rectangle.copyWith(localId: 100)]
    );
    notifyListeners();
  }

  @override
  Future<void> updateRectangle(Rectangle rectangle) async {
    final index = _item.rectangles.indexWhere((r) => r.localId == rectangle.localId);
    if (index != -1) {
      final updatedRects = List<Rectangle>.from(_item.rectangles);
      updatedRects[index] = rectangle;
      _item = _item.copyWith(rectangles: updatedRects);
      notifyListeners();
    }
  }

  @override Future<void> deleteRectangle(int localId) async {}
  @override Future<void> updateItem(Item item) async {}
  @override Future<void> loadClients() async {}
  @override List<Client> get clients => [];
  @override bool get isLoading => false;
  @override Future<void> addClient(Client client) async {}
  @override Future<void> updateClient(Client client) async {}
  @override Future<void> deleteClient(int localId) async {}
  @override Future<int> addItem(Item item) async => 0;
  @override Future<void> deleteItem(int localId) async {}
  @override Future<void> applyBulkPrice(int clientLocalId, double price) async {}
}

class MockSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override List<DefaultPrice> get defaultPrices => [];
  @override Future<void> loadSettings() async {}
  @override double get firstDefaultPrice => 45.0;
  @override Future<void> addDefaultPrice(double price) async {}
  @override Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {}
  @override Future<void> deleteDefaultPrice(int localId) async {}
}

void main() {
  testWidgets('ItemDetailScreen edit rectangle test', (WidgetTester tester) async {
    final rect = Rectangle(localId: 1, itemId: 1, length: 10, width: 20);
    final item = Item(name: 'Test Item', price: 10.0, localId: 1, rectangles: [rect]);

    final mockProvider = MockClientProvider(item);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockProvider),
          ChangeNotifierProvider<SettingsProvider>.value(value: mockSettingsProvider),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('10.0 x 20.0'), findsOneWidget);

    final editIconFinder = find.byIcon(Icons.edit_outlined);
    expect(editIconFinder, findsOneWidget); 
    
    await tester.tap(editIconFinder);
    await tester.pumpAndSettle();

    expect(find.text('Edit Rectangle'), findsOneWidget);
    
    // Change length to 15
    final lengthField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextField, 'Length'),
    );
    await tester.enterText(lengthField, '15.0');
    
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('15.0 x 20.0'), findsOneWidget);
    expect(find.text('Area: 300.00 sqft'), findsOneWidget);
  });
}
