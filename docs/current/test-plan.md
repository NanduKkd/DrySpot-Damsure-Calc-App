# Test Plan: Warranty & Proposal PDF Update

This test plan outlines the testing strategy for the Warranty and Proposal PDF update, ensuring that PDFs are correctly generated, stored, synced, and managed through the new UI.

## 1. Objectives
- Verify the creation and persistence of Proposal metadata on both backend and mobile.
- Verify the updated Warranty metadata persistence and the "one-warranty-per-client" constraint.
- Validate the new PDF Management UI and its integration with existing screens.
- Ensure seamless synchronization of PDF metadata (Warranties and Proposals) between devices.
- Confirm that PDF generation correctly incorporates dynamic data from the new Warranty form.

## 2. Test Strategy

### 2.1 Backend Tests (Node.js/Jest)
- **Unit Tests**:
  - `Proposal` model: Ensure correct fields and associations.
  - `proposalController`: Test uploading a proposal, retrieving a list for a client, and deleting a proposal.
  - `warrantyController`: Test the updated upload logic and ensure it enforces the one-warranty rule (replacing or preventing duplicate warranties).
  - `syncController`: Test that `warranties` and `proposals` are correctly included in the sync payload and response.
- **Integration Tests**:
  - End-to-end flow of uploading a PDF and then performing a sync to see it reflected in the sync response.

### 2.2 Flutter Tests (Dart/Flutter Test)
- **Unit Tests**:
  - `Proposal` model: Verify JSON serialization/deserialization.
  - `DbService`: Test SQLite table creation and CRUD operations for `proposals` and `warranties`.
  - `SyncService`: Test the logic for pushing local changes and pulling remote updates for PDFs.
  - `PdfService`: Verify that `generateWarrantyPdf` correctly handles the new dynamic fields.
- **Widget Tests**:
  - `PdfManagementScreen`: Verify tab switching between Warranty and Proposal, and that lists are rendered correctly.
  - `WarrantyFormScreen`: Verify form validation (required fields) and data submission.
  - `MeasurementScreen`: Verify that the old buttons are replaced by the new "PDF Management" icon.
- **Integration Tests**:
  - Full flow: Client details -> PDF Management -> Create Warranty -> Fill Form -> Submit -> Verify PDF appears in list and is marked as dirty for sync.

## 3. Test Cases

### 3.1 Backend Test Cases

| ID | Description | Expected Result |
| :--- | :--- | :--- |
| BE-1 | Create a Proposal record | Record is saved in the database with `pdf_url` and `client_id`. |
| BE-2 | Upload Warranty (New) | Creates a new record; if one exists, it is replaced or updated. |
| BE-3 | Sync Proposals/Warranties | `POST /api/sync` returns new items and accepts local changes for these entities. |
| BE-4 | Delete Proposal | Record is removed from the database (or marked deleted). |

### 3.2 Flutter Test Cases

| ID | Description | Expected Result |
| :--- | :--- | :--- |
| FL-1 | SQLite CRUD for Proposals | Proposals can be inserted, queried, and deleted locally. |
| FL-2 | Sync PDF Metadata | Local `is_dirty` items are sent to backend; remote items are saved locally. |
| FL-3 | Warranty Form Validation | Cannot submit the warranty form with empty required fields. |
| FL-4 | Tab Switching in PDF Management | Clicking "Proposal" tab shows proposal list; "Warranty" tab shows warranty. |
| FL-5 | One-Warranty Constraint (UI) | Creating a new warranty when one exists shows a confirmation dialog to delete the old one. |

## 4. Execution Commands
- **Backend**: `npm --prefix backend run test`
- **Flutter (Unit/Widget)**: `cd flutter && flutter test`
- **Flutter (Integration)**: `cd flutter && flutter test integration_test/app_test.dart` (Note: Requires environment setup)

## 5. Exit Criteria
- All backend tests pass.
- All Flutter unit and widget tests pass.
- Manual verification of the PDF generation and sync flow is successful.
