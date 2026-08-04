import 'package:app_client/src/services/warranty_replacement_intent_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('replacement target and idempotency identity survive store restart',
      () async {
    const sourceWarrantyId = 'source-warranty-id';
    final firstProcess = WarrantyReplacementIntentStore();
    final created = await firstProcess.loadOrCreate(sourceWarrantyId);

    final restartedProcess = WarrantyReplacementIntentStore();
    final retried = await restartedProcess.loadOrCreate(sourceWarrantyId);

    expect(retried.sourceWarrantyId, sourceWarrantyId);
    expect(retried.idempotencyKey, created.idempotencyKey);
    expect(retried.targetWarrantyId, created.targetWarrantyId);
    expect(retried.targetWarrantyId, isNot(retried.idempotencyKey));

    await restartedProcess.clear(sourceWarrantyId);
    final nextReplacement =
        await WarrantyReplacementIntentStore().loadOrCreate(sourceWarrantyId);
    expect(nextReplacement.idempotencyKey, isNot(created.idempotencyKey));
    expect(nextReplacement.targetWarrantyId, isNot(created.targetWarrantyId));
  });
}
