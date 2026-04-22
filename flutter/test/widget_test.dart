import 'package:app_client/src/providers/auth_provider.dart';
import 'package:app_client/src/providers/client_provider.dart';
import 'package:app_client/src/providers/theme_provider.dart';
import 'package:app_client/src/screens/auth/login_screen.dart';
import 'package:app_client/src/screens/clients/client_list_screen.dart';
import 'package:app_client/src/screens/splash_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeApiService extends ApiService {
  @override
  Future<Map<String, dynamic>> login(String email, String password) async {
    return {
      'token': 'fake_token',
      'user': {
        'id': 'user_id',
        'name': 'Fake User',
        'franchisee_id': 'franchisee_id',
      }
    };
  }
}

class TestAuthProvider extends AuthProvider {
  TestAuthProvider()
      : super(apiService: ApiService(serverUrl: 'http://localhost:3000'));

  bool _authenticated = true;

  @override
  bool get isAuthenticated => _authenticated;

  @override
  Future<void> logout() async {
    _authenticated = false;
    notifyListeners();
  }
}

Widget buildAuthGate(ApiService apiService) {
  return MultiProvider(
    providers: [
      Provider<ApiService>.value(value: apiService),
      ChangeNotifierProvider(
        create: (_) => AuthProvider(apiService: apiService)..tryAutoLogin(),
      ),
    ],
    child: Consumer<AuthProvider>(
      builder: (context, auth, _) {
        return MaterialApp(
          home: auth.isRestoringSession
              ? const SplashScreen()
              : auth.isAuthenticated
                  ? const Scaffold(body: Text('Authenticated'))
                  : const LoginScreen(showBackendUrlButton: false),
        );
      },
    ),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('renders the login screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(buildAuthGate(FakeApiService()));

    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.bySemanticsLabel('DrySpot logo'), findsOneWidget);

    await tester
        .pump(AuthProvider.minimumSplashDuration - const Duration(seconds: 1));

    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('DrySpot Uppala Login'), findsOneWidget);
  });

  testWidgets('restores a saved session on app launch', (tester) async {
    SharedPreferences.setMockInitialValues({
      'token': 'saved_token',
      'user_name': 'Saved User',
      'franchisee_id': 'franchisee_id',
    });

    await tester.pumpWidget(buildAuthGate(FakeApiService()));

    await tester
        .pump(AuthProvider.minimumSplashDuration - const Duration(seconds: 1));

    expect(find.byType(SplashScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(find.text('Authenticated'), findsOneWidget);
    expect(find.text('DrySpot Uppala Login'), findsNothing);
  });

  testWidgets('signing out from settings returns to the login screen', (
    tester,
  ) async {
    final apiService = ApiService(serverUrl: 'http://localhost:3000');
    final authProvider = TestAuthProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiService>.value(value: apiService),
          ChangeNotifierProvider<AuthProvider>.value(value: authProvider),
          ChangeNotifierProvider<ThemeProvider>(
            create: (_) => ThemeProvider(),
          ),
          ChangeNotifierProvider<ClientProvider>(
            create: (_) => ClientProvider(),
          ),
        ],
        child: Consumer<AuthProvider>(
          builder: (context, auth, _) {
            return MaterialApp(
              key: ValueKey(auth.isAuthenticated),
              home: auth.isAuthenticated
                  ? const ClientListScreen()
                  : const LoginScreen(showBackendUrlButton: false),
            );
          },
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.text('Sign Out'), findsOneWidget);

    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();

    expect(find.text('DrySpot Uppala Login'), findsOneWidget);
    expect(authProvider.isAuthenticated, isFalse);
  });
}
