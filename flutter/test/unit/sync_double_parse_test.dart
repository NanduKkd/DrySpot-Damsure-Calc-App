import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/default_price.dart';

void main() {
  group('Double Parsing Error Reproduction', () {
    test('Client.fromMap should handle String representations of doubles', () {
      final map = {
        'remote_id': 'client-uuid-123',
        'name': 'Test Client',
        'latitude': '12.34',
        'longitude': '56.78',
        'discounted_price': '60.00',
        'is_dirty': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final client = Client.fromMap(map);
      expect(client.latitude, 12.34);
      expect(client.longitude, 56.78);
      expect(client.discountedPrice, 60.00);
    });

    test('Item.fromMap should handle String representations of doubles', () {
      final map = {
        'remote_id': 'item-uuid-123',
        'name': 'Test Item',
        'price': '100.00',
        'enabled': 1,
        'is_dirty': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final item = Item.fromMap(map);
      expect(item.price, 100.0);
    });

    test('Rectangle.fromMap should handle String representations of doubles', () {
      final map = {
        'remote_id': 'rect-uuid-123',
        'length': '10.5',
        'width': '20.5',
        'is_dirty': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final rect = Rectangle.fromMap(map);
      expect(rect.length, 10.5);
      expect(rect.width, 20.5);
    });

    test('DefaultPrice.fromMap should handle String representations of doubles', () {
      final map = {
        'remote_id': 'dp-uuid-123',
        'price': '150.00',
        'enabled': 1,
        'updated_at': DateTime.now().toIso8601String(),
      };

      final price = DefaultPrice.fromMap(map);
      expect(price.price, 150.0);
    });
  });
}
