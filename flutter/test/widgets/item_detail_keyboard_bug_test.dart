import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/item_detail_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
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
    final newRects = List<Rectangle>.from(_item.rectangles)..add(rectangle);
    _item = _item.copyWith(rectangles: newRects);
    notifyListeners();
  }

  @override
  Future<void> updateItem(Item item) async {}

  @override
  Future<void> loadClients() async {}

  @override
  Future<void> updateRectangle(Rectangle rectangle) async {}

  @override
  Future<void> deleteRectangle(int localId) async {}

  // Provide other required overrides with empty implementations
  @override
  get clients => [];
  @override
  get isLoading => false;
  @override
  Future<void> addClient(client) async {}
  @override
  Future<void> updateClient(client) async {}
  @override
  Future<void> deleteClient(id) async {}
  @override
  Future<int> addItem(item) async {
    return 1;
  }

  @override
  Future<void> deleteItem(id) async {}
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
  testWidgets(
      'ItemDetailScreen retains focus and keyboard after submitting new rectangle',
      (WidgetTester tester) async {
    // Setup a dummy item with no rectangles
    final item =
        Item(name: 'Test Item', price: 10.0, localId: 1, rectangles: []);

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
          home: Scaffold(
            body: ItemDetailScreen(itemLocalId: 1),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify initial focus is on Length
    final lengthFieldFinder = find.widgetWithText(TextField, 'Length (ft)');
    final widthFieldFinder = find.widgetWithText(TextField, 'Width (ft)');

    expect(lengthFieldFinder, findsOneWidget);
    expect(widthFieldFinder, findsOneWidget);

    // Enter length
    await tester.enterText(lengthFieldFinder, '10');
    // Move to width
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    // Enter width
    await tester.enterText(widthFieldFinder, '20');
    // Submit width (TextInputAction.next)
    await tester.testTextInput.receiveAction(TextInputAction.next);

    // Pump a few times to allow async operations and animations
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));

    // After submission, there should be one new rectangle in the list (the saved one)
    expect(find.text('200.0 sqft'), findsOneWidget);

    // And there should be a fresh empty input row for the next rectangle
    expect(lengthFieldFinder, findsNWidgets(2));
    expect(widthFieldFinder, findsNWidgets(2));

    // The Length text field should be focused so the keyboard remains visible
    final lengthTextField = tester.widget<TextField>(lengthFieldFinder.last);
    expect(lengthTextField.focusNode?.hasFocus, isTrue,
        reason: 'Length field should have focus after submission');
  });
}
