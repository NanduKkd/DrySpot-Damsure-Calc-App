import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';

void main() {
  group('Client Model Phone Field', () {
    test('toMap should include phone field', () {
      final client = Client(
        name: 'Test Client',
        phone: '1234567890',
      );
      final map = client.toMap();
      expect(map['phone'], '1234567890');
    });

    test('fromMap should parse phone field', () {
      final map = {
        'remote_id': 'c1',
        'name': 'Test Client',
        'phone': '0987654321',
        'updated_at': DateTime.now().toIso8601String(),
        'is_dirty': 1,
      };
      final client = Client.fromMap(map);
      expect(client.phone, '0987654321');
    });

    test('copyWith should update phone field', () {
      final client = Client(name: 'Test Client', phone: '111');
      final updated = client.copyWith(phone: '222');
      expect(updated.phone, '222');
      expect(updated.name, 'Test Client');
    });
  });
}
