import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/client.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/services/db_service.dart';
import 'package:app_client/src/services/api_service.dart';
import 'package:mockito/mockito.dart';

class MockApiService extends Mock implements ApiService {}

class MockDbService extends Mock implements DbService {}

void main() {
  test('Simulate sync response', () async {
    final clientMap = {
      'remote_id': 'c-1',
      'name': 'Client 1',
      'updated_at': DateTime.now().toIso8601String(),
    };
    final itemMap = {
      'remote_id': 'i-1',
      'client_id': 'c-1',
      'name': 'Item 1',
      'price': 100,
      'enabled': true,
      'updated_at': DateTime.now().toIso8601String(),
    };
    final rectMap = {
      'remote_id': 'r-1',
      'item_id': 'i-1',
      'length': 10,
      'width': 10,
      'image_data': 'data:image/png;base64,ZmFrZQ==',
      'updated_at': DateTime.now().toIso8601String(),
    };

    final client = Client.fromMap(clientMap);
    final item = Item.fromMap(itemMap).copyWith(clientId: 1, isDirty: false);
    final rect = Rectangle.fromMap(rectMap).copyWith(itemId: 1, isDirty: false);

    expect(client.remoteId, 'c-1');
    expect(item.remoteId, 'i-1');
    expect(rect.remoteId, 'r-1');
    expect(rect.imageData, 'data:image/png;base64,ZmFrZQ==');
  });
}
