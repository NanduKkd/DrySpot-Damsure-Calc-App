# Technical Design: Item Editing, Client Discounts, and Proposal Generation

## Architecture Summary
The system will be enhanced to allow editing of existing rectangle dimensions, which will automatically update associated item and client totals. A `discountedPrice` field will be added to the `Client` model across the stack (PostgreSQL, SQLite, and Flutter/Node.js models) to allow manual overrides of the total calculated price. The UI will provide real-time calculation of discount amount and percentage. Finally, a new `generateProposalPdf` method will be added to `PdfService` to provide clients with a detailed, professional PDF summary of their project, including itemized areas and final discounted pricing.

## Exact Backend File Paths
- `backend/src/models/Client.ts`: Add `discountedPrice` (DataTypes.FLOAT, allowNull: true).
- `backend/src/controllers/syncController.ts`: Update `sync` function to process `discounted_price` in both `changes` and `updates`.

## Exact Flutter App File Paths
- `flutter/lib/src/models/client.dart`: Add `discountedPrice` field and update `fromMap`, `toMap`, `copyWith`, and add `discountAmount` and `discountPercentage` getters.
- `flutter/lib/src/services/db_service.dart`: 
    - Update `_initDatabase` version to 4.
    - Update `_onUpgrade` to add `discounted_price` to `clients`.
    - Update `_onCreate` to include `discounted_price`.
- `flutter/lib/src/services/pdf_service.dart`: Add `generateProposalPdf(Client client)` method.
- `flutter/lib/src/providers/client_provider.dart`: Ensure `updateClient` and `updateRectangle` are ready (already implemented, just need to use them).
- `flutter/lib/src/screens/clients/item_detail_screen.dart`: 
    - Add an "Edit" icon to rectangle list items.
    - Add `_showEditRectangleDialog(Rectangle rect)` method.
- `flutter/lib/src/screens/clients/measurement_screen.dart`:
    - Add `_showDiscountDialog()` to set `discountedPrice`.
    - Add "Apply Discount" button/icon in the summary area or AppBar.
    - Add "Generate Proposal" icon in the AppBar (using `Icons.description`).
    - Update summary display to show both original and discounted price.
- `flutter/lib/src/services/sync_service.dart`: Ensure `discounted_price` is included in the maps sent to and received from the API.

## Data Model Definitions

### Backend (Sequelize) - `Client`
```typescript
{
  discountedPrice: {
    type: DataTypes.FLOAT,
    allowNull: true,
  }
}
```

### Flutter (SQLite) - `clients`
```sql
ALTER TABLE clients ADD COLUMN discounted_price REAL;
```

### Flutter (Dart) - `Client`
```dart
class Client {
  final double? discountedPrice;
  // ... other fields

  double get totalArea => // sum of item areas
  double get originalTotalPrice => // sum of item totalPrices
  double get finalTotalPrice => discountedPrice ?? originalTotalPrice;
  double get discountAmount => originalTotalPrice - finalTotalPrice;
  double get discountPercentage => originalTotalPrice > 0 ? (discountAmount / originalTotalPrice) * 100 : 0;
}
```

## API Contract
`POST /sync`
- Request `changes.clients`: Each client object includes `discounted_price` (nullable float).
- Response `updates.clients`: Each client object includes `discounted_price` (nullable float).

## Test Targets
- `backend/src/controllers/syncController.test.ts`: Verify `discountedPrice` is correctly upserted and returned.
- `flutter/test/unit/client_discount_test.dart`: Test `discountAmount` and `discountPercentage` logic.
- `flutter/test/widgets/item_detail_edit_test.dart`: Verify rectangle editing updates UI and provider.
- `flutter/test/widgets/measurement_screen_discount_test.dart`: Verify discount dialog calculations and summary display.

## Verification Plan
1. **Rectangle Editing:**
    - Open `ItemDetailScreen` for an item.
    - Tap "Edit" icon on a rectangle.
    - Change dimensions and save.
    - Verify item area and total price update immediately.
2. **Client Discount:**
    - Open `MeasurementScreen`.
    - Tap "Apply Discount" button.
    - Enter a discounted price.
    - Verify "Discount Amount" and "Discount Percentage" are correct in the dialog.
    - Save and verify the summary shows original price (strikethrough) and discounted price.
3. **Proposal Generation:**
    - Tap the proposal icon in `MeasurementScreen`.
    - Verify the PDF contains: item list, individual areas, individual prices, total area, original total, discount, and final price.
4. **Sync:**
    - Set a discount on Device A, sync.
    - Sync Device B, verify the same discount is visible.

## Import/Path Rules
- Use `package:dryspot_damsure_calc_app/...` for all internal imports.
- Maintain `db_service.dart` as the single point of entry for SQLite.
- Ensure all business logic for price calculations remains within the `Client` and `Item` models.

READY_FOR_TESTS_AND_DEV
