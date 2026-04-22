import 'package:flutter_test/flutter_test.dart';
import 'package:app_client/src/models/item.dart';
import 'package:app_client/src/models/proposal.dart';
import 'package:app_client/src/models/rectangle.dart';
import 'package:app_client/src/models/warranty.dart';

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

    test('Warranty.fromMap should handle String client_id from server', () {
      final serverWarrantyMap = {
        'remote_id': 'warranty-uuid-123',
        'client_id': 'client-uuid-456', // Server sends UUID string
        'warranty_card_number': 'W-123',
        'start_date': DateTime.now().toIso8601String(),
        'duration_years': 5,
        'pdf_url': 'https://example.com/warranty.pdf',
        'is_dirty': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final warranty = Warranty.fromMap(serverWarrantyMap);
      expect(warranty.remoteId, 'warranty-uuid-123');
      expect(warranty.clientId, 0);
      expect(warranty.remoteClientId, 'client-uuid-456');
    });

    test('Proposal.fromMap should handle String client_id from server', () {
      final serverProposalMap = {
        'remote_id': 'proposal-uuid-123',
        'client_id': 'client-uuid-456', // Server sends UUID string
        'pdf_url': 'https://example.com/proposal.pdf',
        'is_dirty': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'deleted_at': null,
      };

      final proposal = Proposal.fromMap(serverProposalMap);
      expect(proposal.remoteId, 'proposal-uuid-123');
      expect(proposal.clientId, 0);
      expect(proposal.remoteClientId, 'client-uuid-456');
    });
  });
}
