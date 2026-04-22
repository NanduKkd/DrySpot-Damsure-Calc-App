import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/services/api_service.dart';

class FakeApiService extends ApiService {
  FakeApiService() : super(serverUrl: 'http://localhost:3000');

  Map<String, dynamic>? loginResponse;

  @override
  Future<Map<String, dynamic>> login(String email, String password) async {
    if (loginResponse == null) {
      throw StateError('loginResponse must be set before calling login');
    }

    return loginResponse!;
  }
}

void main() {
  group('AuthProvider Franchisee Name', () {
    late FakeApiService mockApiService;
    late AuthProvider authProvider;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockApiService = FakeApiService();
      authProvider = AuthProvider(apiService: mockApiService);
    });

    test('login should parse and store franchisee_name', () async {
      mockApiService.loginResponse = {
        'token': 'mock_token',
        'user': {
          'name': 'Test User',
          'franchisee_id': 'FRANCH-123',
          'franchisee_name': 'Authorized Franchisee of Damsure'
        }
      };

      await authProvider.login('test@example.com', 'password');

      expect(authProvider.franchiseeName, 'Authorized Franchisee of Damsure');

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('franchisee_name'),
        'Authorized Franchisee of Damsure',
      );
    });

    test('tryAutoLogin should retrieve franchisee_name from SharedPreferences',
        () async {
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
