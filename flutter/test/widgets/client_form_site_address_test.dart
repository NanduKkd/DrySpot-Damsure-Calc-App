import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:app_client/src/screens/clients/client_form_screen.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'client_form_site_address_test.mocks.dart';

class MockApiService extends Mock implements ApiService {}

class FakeAuthProvider extends ChangeNotifier implements AuthProvider {
  @override
  String? get franchiseeId => 'test-franchisee';
  
  @override
  String? get franchiseeName => 'Test Franchisee Name';
  
  @override
  bool get isAuthenticated => true;
  
  String? get token => 'dummy-token';

  @override
  String? get userName => 'Test User';

  @override
  late final ApiService apiService = MockApiService();

  @override
  Future<void> login(String email, String password) async {}

  @override
  Future<void> logout() async {}
  
  Future<void> checkAuthStatus() async {}

  @override
  Future<void> tryAutoLogin() async {}
}

@GenerateMocks([ClientProvider])
void main() {
  group('ClientFormScreen Site Address Field', () {
    late MockClientProvider mockClientProvider;

    setUp(() {
      mockClientProvider = MockClientProvider();
      when(mockClientProvider.clients).thenReturn([]);
    });

    Widget createWidgetUnderTest() {
      return MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<ClientProvider>.value(value: mockClientProvider),
            ChangeNotifierProvider<AuthProvider>(create: (_) => FakeAuthProvider()),
          ],
          child: const ClientFormScreen(),
        ),
      );
    }

    testWidgets('displays Site Address field and saves it', (WidgetTester tester) async {
      await tester.pumpWidget(createWidgetUnderTest());

      expect(find.text('Site Address'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).at(0), 'Test Client');
      await tester.enterText(find.byType(TextFormField).at(2), '123 Build Site');
      
      await tester.tap(find.byType(ElevatedButton).first);
      await tester.pumpAndSettle();

      verify(mockClientProvider.addClient(argThat(
        isA<Client>()
          .having((c) => c.name, 'name', 'Test Client')
          .having((c) => c.siteAddress, 'siteAddress', '123 Build Site')
      ))).called(1);
    });
  });
}
