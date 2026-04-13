import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/services/api_service.dart';

import 'auth_provider_franchisee_test.mocks.dart';

@GenerateMocks([ApiService])
void main() {
  group('AuthProvider Franchisee Name', () {
    late MockApiService mockApiService;
    late AuthProvider authProvider;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApiService = MockApiService();
      authProvider = AuthProvider(apiService: mockApiService);
    });

    test('login should parse and store franchisee_name', () async {
      when(mockApiService.login('test@example.com', 'password')).thenAnswer(
        (_) async => {
          'token': 'mock_token',
          'user': {
            'name': 'Test User',
            'franchisee_id': 'FRANCH-123',
            'franchisee_name': 'Authorized Franchisee of Damsure'
          }
        },
      );

      await authProvider.login('test@example.com', 'password');

      expect(authProvider.franchiseeName, 'Authorized Franchisee of Damsure');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('franchisee_name'), 'Authorized Franchisee of Damsure');
    });

    test('tryAutoLogin should retrieve franchisee_name from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'mock_token',
        'user_name': 'Test User',
        'franchisee_id': 'FRANCH-123',
        'franchisee_name': 'Stored Franchisee Name',
      });

      await authProvider.tryAutoLogin();

      expect(authProvider.franchiseeName, 'Stored Franchisee Name');
    });

    test('logout should clear franchisee_name', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'mock_token',
        'user_name': 'Test User',
        'franchisee_id': 'FRANCH-123',
        'franchisee_name': 'Stored Franchisee Name',
      });

      await authProvider.tryAutoLogin();
      expect(authProvider.franchiseeName, isNotNull);

      await authProvider.logout();
      expect(authProvider.franchiseeName, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('franchisee_name'), isFalse);
    });
  });
}
