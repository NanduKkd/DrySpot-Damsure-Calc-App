import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/item_detail_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';

import 'package:app_client/src/models/default_price.dart';

// We need a way to mock or provide a pre-filled ClientProvider for the test
class MockClientProvider extends ClientProvider {
  final Item _item;
  MockClientProvider(this._item);

  @override
  Future<Item?> getItemByLocalId(int localId) async {
    return _item;
  }

  @override
  Future<void> addRectangle(Rectangle rectangle) async {}
  @override
  Future<void> updateItem(Item item) async {}
  @override
  Future<void> loadClients() async {}
}

class DeletionClientProvider extends MockClientProvider {
  DeletionClientProvider(super.item);

  int deleteCount = 0;
  Completer<void>? deletionCompleter;

  @override
  Future<void> deleteRectangle(int localId) async {
    deleteCount++;
    await deletionCompleter?.future;
  }
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
  testWidgets('ItemDetailScreen focus movement test',
      (WidgetTester tester) async {
    // Setup a dummy item
    final item = Item(name: 'Test Item', price: 10.0, localId: 1);

    final mockProvider = MockClientProvider(item);
    final mockSettingsProvider = MockSettingsProvider();

    // Provide necessary state
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

    await tester.pumpAndSettle(); // Wait for _loadItem

    // Initial focus should be on length field of first row (the new entry row)
    final lengthFieldFinder = find.widgetWithText(TextField, 'Length (ft)');
    expect(lengthFieldFinder, findsOneWidget);

    // Type Length and press Next
    await tester.enterText(lengthFieldFinder, '10');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    // Focus should be on width field
    final widthFieldFinder = find.widgetWithText(TextField, 'Width (ft)');
    expect(widthFieldFinder, findsOneWidget);

    // Type Width and press Next
    await tester.enterText(widthFieldFinder, '20');
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    // Verify focus is back on Length
    expect(find.widgetWithText(TextField, 'Length (ft)'), findsOneWidget);
  });

  testWidgets('ItemDetailScreen shows total area for entered rectangles',
      (WidgetTester tester) async {
    final item = Item(
      name: 'Test Item',
      price: 10.0,
      localId: 1,
      rectangles: [
        Rectangle(itemId: 1, length: 10, width: 10),
        Rectangle(itemId: 1, length: 4, width: 10),
      ],
    );

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

    expect(find.text('Total Area: 140.00 sqft'), findsOneWidget);
    expect(find.text('Total Cost: ₹1400.00'), findsOneWidget);
  });

  testWidgets('ItemDetailScreen shows when a rectangle image is attached',
      (WidgetTester tester) async {
    const rectangleImage =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO5Vm9sAAAAASUVORK5CYII=';

    final item = Item(
      name: 'Test Item',
      price: 10.0,
      localId: 1,
      rectangles: [
        Rectangle(
          itemId: 1,
          length: 10,
          width: 10,
          imageData: rectangleImage,
        ),
      ],
    );

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

    expect(find.text('Image attached'), findsOneWidget);
  });

  testWidgets('measurement deletion confirms dimensions and is single-flight',
      (WidgetTester tester) async {
    final item = Item(
      name: 'Test Item',
      price: 10.0,
      localId: 1,
      rectangles: [
        Rectangle(
          localId: 7,
          itemId: 1,
          length: 12,
          width: 8,
          imageData: 'data:image/png;base64,ZmFrZQ==',
        ),
      ],
    );
    final mockProvider = DeletionClientProvider(item)
      ..deletionCompleter = Completer<void>();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: MockSettingsProvider()),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete Measurement'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 12 ft × 8 ft measurement?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Confirm'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(mockProvider.deleteCount, 1);

    await tester.tap(find.byTooltip('Delete Measurement'));
    await tester.pump();
    expect(mockProvider.deleteCount, 1);

    mockProvider.deletionCompleter!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('measurement deletion Cancel preserves the measurement',
      (WidgetTester tester) async {
    final item = Item(
      name: 'Test Item',
      price: 10.0,
      localId: 1,
      rectangles: [
        Rectangle(
          localId: 7,
          itemId: 1,
          length: 12,
          width: 8,
          imageData: 'data:image/png;base64,ZmFrZQ==',
        ),
      ],
    );
    final mockProvider = DeletionClientProvider(item);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ClientProvider>.value(value: mockProvider),
          ChangeNotifierProvider<SettingsProvider>.value(
              value: MockSettingsProvider()),
        ],
        child: const MaterialApp(
          home: ItemDetailScreen(itemLocalId: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete Measurement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(mockProvider.deleteCount, 0);
    expect(find.text('96.0 sqft'), findsOneWidget);
    expect(find.text('Image attached'), findsOneWidget);
    expect(find.byTooltip('Delete Measurement'), findsOneWidget);
  });
}
