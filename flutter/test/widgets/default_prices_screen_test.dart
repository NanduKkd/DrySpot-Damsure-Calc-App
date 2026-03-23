import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/settings/default_prices_screen.dart';
import 'package:app_client/src/providers/settings_provider.dart';
import 'package:app_client/src/models/default_price.dart';

class MockSettingsProvider extends SettingsProvider {
  final List<DefaultPrice> _defaultPrices = [
    DefaultPrice(localId: 1, price: 10.0, enabled: true),
    DefaultPrice(localId: 2, price: 15.5, enabled: false),
  ];

  @override
  List<DefaultPrice> get defaultPrices => _defaultPrices;

  @override
  Future<void> addDefaultPrice(double price) async {
    _defaultPrices.add(DefaultPrice(localId: 3, price: price, enabled: true));
    notifyListeners();
  }

  @override
  Future<void> deleteDefaultPrice(int localId) async {
    _defaultPrices.removeWhere((p) => p.localId == localId);
    notifyListeners();
  }
}

void main() {
  testWidgets('DefaultPricesScreen displays prices and allows adding', (WidgetTester tester) async {
    final mockSettingsProvider = MockSettingsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: mockSettingsProvider,
        child: const MaterialApp(
          home: DefaultPricesScreen(),
        ),
      ),
    );

    // Initial check
    expect(find.text('₹10.00'), findsOneWidget);
    expect(find.text('₹15.50'), findsOneWidget);

    // Add a price
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Price'), '20.0');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(find.text('₹20.00'), findsOneWidget);

    // Delete a price
    await tester.tap(find.byIcon(Icons.delete).first);
    await tester.pumpAndSettle();

    expect(find.text('₹10.00'), findsNothing);
  });
}
