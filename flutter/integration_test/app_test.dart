import 'package:app_client/src/app.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the login screen', (tester) async {
    await tester.pumpWidget(
      App(
        apiService: FakeApiService(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Damsure Login'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });
}
