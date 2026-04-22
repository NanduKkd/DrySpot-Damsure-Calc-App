import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/theme_provider.dart';
import 'package:app_client/src/screens/clients/client_list_screen.dart';
import 'package:app_client/src/screens/clients/warranty_form_screen.dart';
import 'package:app_client/src/screens/settings/settings_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:app_client/src/utils/warranty_date_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestAuthProvider extends AuthProvider {
  _TestAuthProvider()
      : super(apiService: ApiService(serverUrl: 'http://localhost:3000'));

  bool logoutCalled = false;

  @override
  Future<void> logout() async {
    logoutCalled = true;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('warranty form shows 5 to 25 year duration options only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(
              apiService: ApiService(serverUrl: 'http://localhost:3000'),
            ),
          ),
        ],
        child: MaterialApp(
          home: WarrantyFormScreen(
            client: Client(
              localId: 1,
              remoteId: 'client-1',
              name: 'Client',
              address: 'Address',
              siteAddress: 'Site',
              phone: '1234567890',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();

    expect(find.text('5 Years'), findsWidgets);
    expect(find.text('10 Years'), findsOneWidget);
    expect(find.text('15 Years'), findsOneWidget);
    expect(find.text('20 Years'), findsOneWidget);
    expect(find.text('25 Years'), findsOneWidget);
    expect(find.text('1 Years'), findsNothing);
    expect(find.text('2 Years'), findsNothing);
    expect(find.text('3 Years'), findsNothing);
  });

  testWidgets(
      'warranty form starts with an empty card number and derives dates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(
              apiService: ApiService(serverUrl: 'http://localhost:3000'),
            ),
          ),
        ],
        child: MaterialApp(
          home: WarrantyFormScreen(
            client: Client(
              localId: 1,
              remoteId: 'client-1',
              name: 'Client',
              address: 'Address',
              siteAddress: 'Site',
              phone: '1234567890',
            ),
          ),
        ),
      ),
    );

    final today = warrantyDateOnly(DateTime.now());
    final cardNumberField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('warrantyCardNumberField')),
    );
    final areaOfApplicationField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('warrantyAreaOfApplicationField')),
    );
    final startDateField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('warrantyStartDateField')),
    );
    final expiryDateField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('warrantyExpiryDateField')),
    );

    expect(areaOfApplicationField.controller!.text, 'Roof');
    expect(cardNumberField.controller!.text, isEmpty);
    expect(startDateField.controller!.text, formatWarrantyDate(today));
    expect(
      expiryDateField.controller!.text,
      formatWarrantyDate(addWarrantyYears(today, 5)),
    );

    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 Years').last);
    await tester.pumpAndSettle();

    final updatedExpiryDateField = tester.widget<TextFormField>(
      find.byKey(const ValueKey('warrantyExpiryDateField')),
    );

    expect(
      updatedExpiryDateField.controller!.text,
      formatWarrantyDate(addWarrantyYears(today, 10)),
    );
  });

  testWidgets('client list keeps settings in the app bar and removes logout', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => AuthProvider(
              apiService: ApiService(serverUrl: 'http://localhost:3000'),
            ),
          ),
          ChangeNotifierProvider<ClientProvider>(
            create: (_) => ClientProvider(),
          ),
        ],
        child: const MaterialApp(home: ClientListScreen()),
      ),
    );

    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsNothing);
  });

  testWidgets('settings screen exposes sign out action', (tester) async {
    final authProvider = _TestAuthProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );

    expect(find.text('Sign Out'), findsOneWidget);

    await tester.tap(find.text('Sign Out'));
    await tester.pump();

    expect(authProvider.logoutCalled, isTrue);
  });
}
