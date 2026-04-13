import 'package:app_client/src/app.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
  testWidgets('renders the login screen', (tester) async {
    await tester.pumpWidget(
      App(
        apiService: FakeApiService(),
      ),
    );

    expect(find.text('Damsure Login'), findsOneWidget);
  });
}
