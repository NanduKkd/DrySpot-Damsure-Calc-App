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
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/warranty.dart';

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
        rectangles: [..._item.rectangles, rectangle.copyWith(localId: 100)]);
    notifyListeners();
  }

  @override
  Future<void> updateRectangle(Rectangle rectangle) async {
    final index =
        _item.rectangles.indexWhere((r) => r.localId == rectangle.localId);
    if (index != -1) {
      final updatedRects = List<Rectangle>.from(_item.rectangles);
      updatedRects[index] = rectangle;
      _item = _item.copyWith(rectangles: updatedRects);
      notifyListeners();
    }
  }

  @override
  Future<void> deleteRectangle(int localId) async {}
  @override
  Future<void> updateItem(Item item) async {}
  @override
  Future<void> loadClients() async {}
  @override
  List<Client> get clients => [];
  @override
  bool get isLoading => false;
  @override
  Future<void> addClient(Client client) async {}
  @override
  Future<void> updateClient(Client client) async {}
  @override
  Future<void> deleteClient(int localId) async {}
  @override
  Future<int> addItem(Item item) async => 0;
  @override
  Future<void> deleteItem(int localId) async {}
  @override
  Future<void> applyBulkPrice(int clientLocalId, double price) async {}
  @override
  void updateSession({required bool isAuthenticated, String? franchiseeId}) {}
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

class MockSettingsProvider extends ChangeNotifier implements SettingsProvider {
  @override
  List<DefaultPrice> get defaultPrices => [];
  @override
  Future<void> loadSettings() async {}
  @override
  void updateSession({required bool isAuthenticated, String? franchiseeId}) {}
  @override
  double get firstDefaultPrice => 45.0;
  @override
  Future<void> addDefaultPrice(double price) async {}
  @override
  Future<void> updateDefaultPrice(DefaultPrice defaultPrice) async {}
  @override
  Future<void> deleteDefaultPrice(int localId) async {}
}

void main() {
  Future<void> pumpItemDetail(
    WidgetTester tester,
    MockClientProvider provider,
    MockSettingsProvider settings,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: provider),
          ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('invalid new measurements show field errors and retain input',
      (WidgetTester tester) async {
    final item = Item(name: 'Test Item', price: 10.0, localId: 1);
    final provider = MockClientProvider(item);
    await pumpItemDetail(tester, provider, MockSettingsProvider());

    final length = find.widgetWithText(TextField, 'Length (ft)');
    final width = find.widgetWithText(TextField, 'Width (ft)');

    final invalidInputs = <String, String>{
      '': 'Enter Length',
      'abc': 'Enter a valid number',
      '0': 'Length must be greater than 0',
      '-2': 'Length must be greater than 0',
      'Infinity': 'Length must be finite',
      '10001': 'Length must be 10,000 ft or less',
    };

    for (final entry in invalidInputs.entries) {
      final value = entry.key;
      await tester.tap(length);
      await tester.enterText(length, value);
      await tester.tap(width);
      await tester.enterText(width, '2');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      expect(find.text(entry.value), findsOneWidget,
          reason: '$value should be invalid');
      expect(tester.widget<TextField>(length).controller!.text, value);
      expect(tester.widget<TextField>(width).focusNode!.hasFocus, isTrue);
      await tester.tap(length);
      await tester.enterText(length, '10');
    }

    expect(provider._item.rectangles, isEmpty);
  });

  testWidgets('invalid inline measurements show field errors and retain focus',
      (WidgetTester tester) async {
    final rect = Rectangle(localId: 1, itemId: 1, length: 10, width: 20);
    final item =
        Item(name: 'Test Item', price: 10.0, localId: 1, rectangles: [rect]);
    final provider = MockClientProvider(item);
    await pumpItemDetail(tester, provider, MockSettingsProvider());

    final length = find.widgetWithText(TextField, 'Length (ft)').first;
    final width = find.widgetWithText(TextField, 'Width (ft)').first;
    await tester.enterText(length, '10001');
    await tester.tap(width);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(find.text('Length must be 10,000 ft or less'), findsOneWidget);
    expect(tester.widget<TextField>(length).controller!.text, '10001');
    expect(tester.widget<TextField>(width).focusNode!.hasFocus, isTrue);
    expect(provider._item.rectangles.first.length, 10);
  });

  testWidgets('ItemDetailScreen edit rectangle test',
      (WidgetTester tester) async {
    final rect = Rectangle(localId: 1, itemId: 1, length: 10, width: 20);
    final item =
        Item(name: 'Test Item', price: 10.0, localId: 1, rectangles: [rect]);

    final mockProvider = MockClientProvider(item);
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: mockSettingsProvider),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('200.0 sqft'), findsOneWidget);

    // Change length inline, then press Next on width to save the row.
    final lengthField = find.widgetWithText(TextField, 'Length (ft)').first;
    await tester.enterText(lengthField, '15.0');

    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(mockProvider._item.rectangles.first.length, 15.0);
    expect(find.text('300.0 sqft'), findsOneWidget);
  });
}
