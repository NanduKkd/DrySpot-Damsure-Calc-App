import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';

void main() {
  group('Client Model Site Address Field', () {
    test('toMap should include site_address field', () {
      final client = Client(
        name: 'Test Client',
        siteAddress: '123 Site Road',
      );
      final map = client.toMap();
      expect(map['site_address'], '123 Site Road');
    });

    test('fromMap should parse site_address field', () {
      final map = {
        'remote_id': 'c1',
        'name': 'Test Client',
        'site_address': '456 Construction Blvd',
        'updated_at': DateTime.now().toIso8601String(),
        'is_dirty': 1,
      };
      final client = Client.fromMap(map);
      expect(client.siteAddress, '456 Construction Blvd');
    });

    test('copyWith should update siteAddress field', () {
      final client = Client(name: 'Test Client', siteAddress: 'Old Site');
      final updated = client.copyWith(siteAddress: 'New Site');
      expect(updated.siteAddress, 'New Site');
      expect(updated.name, 'Test Client');
    });
  });
}
