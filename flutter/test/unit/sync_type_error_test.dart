import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';

void main() {
  group('Sync Type Error Reproduction', () {
    test('Item.fromMap should handle String client_id from server', () {
      final serverItemMap = {
        'remote_id': 'item-uuid-123',
        'client_id': 'client-uuid-456', // Server sends UUID string
        'name': 'Test Item',
        'price': 100.0,
        'enabled': 1,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final item = Item.fromMap(serverItemMap);
      expect(item.remoteId, 'item-uuid-123');
      expect(item.clientId, isNull);
    });

    test('Rectangle.fromMap should handle String item_id from server', () {
      final serverRectMap = {
        'remote_id': 'rect-uuid-789',
        'item_id': 'item-uuid-123', // Server sends UUID string
        'length': 10.0,
        'width': 20.0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final rect = Rectangle.fromMap(serverRectMap);
      expect(rect.remoteId, 'rect-uuid-789');
      expect(rect.itemId, isNull);
    });
  });
}
