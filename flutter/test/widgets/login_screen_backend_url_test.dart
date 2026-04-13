import 'package:app_client/src/screens/auth/login_screen.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('hides the backend URL button when disabled', (tester) async {
    final apiService = ApiService(serverUrl: 'http://localhost:3000');

    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: apiService,
        child: const MaterialApp(
          home: LoginScreen(showBackendUrlButton: false),
        ),
      ),
    );

    expect(find.text('Change Backend URL'), findsNothing);
    expect(find.textContaining('Backend URL:'), findsNothing);
  });

  testWidgets('updates the backend URL from the login screen', (tester) async {
    final apiService = ApiService(serverUrl: 'http://localhost:3000');

    await tester.pumpWidget(
      Provider<ApiService>.value(
        value: apiService,
        child: const MaterialApp(
          home: LoginScreen(showBackendUrlButton: true),
        ),
      ),
    );

    expect(find.text('Backend URL: http://localhost:3000/api'), findsOneWidget);

    await tester.tap(find.text('Change Backend URL'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).last,
      'http://10.0.2.2:3000/api',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Backend URL: http://10.0.2.2:3000/api'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_url'), 'http://10.0.2.2:3000');
  });
}
