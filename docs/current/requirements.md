# Requirements: Item Editing, Client Discounts, and Proposal Generation

## Feature Summary
Enhance the item measurement process by allowing existing rectangles to be edited. Add a client-level discount feature that allows users to override the calculated total price with a custom discounted price. Finally, provide a "Generate Proposal" option for each client that exports a detailed PDF summary of items, areas, and final pricing including discounts.

## In scope
- **Editable Rectangles:**
    - Allow users to edit existing rectangles (length and width) within the `ItemDetailScreen`.
    - Update the item's total area and price immediately upon saving.
- **Client Discounting:**
    - Add a `discountedPrice` field to the `Client` model (both Flutter and Backend).
    - Provide a UI in `MeasurementScreen` to enter a discounted price.
    - Pre-fill the discount field with the current calculated total.
    - Calculate and display the discount amount and percentage in real-time.
    - Display both the original calculated total and the discounted price on the `MeasurementScreen`.
- **Proposal Generation:**
    - Add a "Generate Proposal" feature in `MeasurementScreen`.
    - Generate a PDF proposal including:
        - List of items with their individual measurements (area), price per sqft, and total item price.
        - Overall total area.
        - Original calculated total price.
        - Applied discount amount and final discounted price.
- **Database Schema Updates:**
    - Add `discounted_price` (REAL) to the `clients` table in the local SQLite database.
    - Add `discountedPrice` (FLOAT) to the `clients` table in the backend PostgreSQL database.
- **Synchronization:**
    - Ensure the `discountedPrice` field is synchronized between the mobile app and the backend.

## Out of scope
- Item-level discounts (discounts are applied to the client's total).
- Complex discount rules (e.g., percentage-based caps).
- Customizing the proposal PDF template beyond the specified fields.
- Storing a history of previous discount values (only the current one is saved).

## User flows
### 1. Editing a Rectangle
1.  Navigate to a Client's Measurements.
2.  Select an Item (e.g., "Roof").
3.  On the `ItemDetailScreen`, tap an existing rectangle entry or its edit icon.
4.  An "Edit Rectangle" dialog appears with the current Length and Width.
5.  Modify the dimensions and tap "Save".
6.  The rectangle list and item summary are updated.

### 2. Applying a Client Discount
1.  Navigate to a Client's `MeasurementScreen`.
2.  Tap the "Apply Discount" button (newly added).
3.  A dialog shows the "Original Total Price".
4.  The user enters a value in the "Discounted Price" field (pre-filled with the original price).
5.  The dialog displays "Discount Amount: ₹X.XX" and "Discount Percentage: X.X%" as the user types.
6.  Tap "Save".
7.  The `MeasurementScreen` now shows the Original Total (strikethrough) and the Discounted Price.

### 3. Generating a Proposal
1.  On the `MeasurementScreen`, tap the "Generate Proposal" icon/button.
2.  A PDF is generated and a system share sheet opens.
3.  The user can share the PDF with the client via WhatsApp, Email, etc.

## Validation and error handling rules
- **Rectangle Editing:** Length and width must be positive numeric values.
- **Discounting:**
    - Discounted price must be a non-negative numeric value.
    - If the user enters a discounted price higher than the original, the discount amount and percentage will be shown as negative (or the UI can prevent it if preferred, but for now, simple validation is enough).
    - If no discount is applied (field matches original), the `discountedPrice` can be stored as null or the original value.
- **Proposal:** Proposal can only be generated if the client has at least one item.

## Non-functional requirements
- PDF generation should be fast and occur locally on the device.
- UI updates for area and price calculations must be near-instant.
- Synchronized data must include the discount field to ensure consistency across devices.

## Acceptance criteria
- [ ] Rectangles in `ItemDetailScreen` can be edited, not just deleted.
- [ ] `MeasurementScreen` has a functional discount feature that calculates amount and percentage.
- [ ] `MeasurementScreen` UI correctly reflects the discounted price vs. original total.
- [ ] "Generate Proposal" produces a professional PDF with itemized details and final pricing (including discount).
- [ ] All new fields (discounted price) are correctly persisted locally and synced to the backend.
- [ ] Database migrations are handled for both Flutter (SQLite) and Backend (Sequelize).

## Open assumptions
- The "calculated price" refers to the sum of all enabled items' prices (`totalPrice` of the client).
- The "discounted price" is an absolute override of the total price, not a percentage off.
- The user wants to see the discount percentage for informational purposes, even if they enter the absolute price.
- `discountedPrice` is stored as a nullable double in both local and remote databases. If null, no discount is applied.

`READY_FOR_IMPLEMENTATION`
