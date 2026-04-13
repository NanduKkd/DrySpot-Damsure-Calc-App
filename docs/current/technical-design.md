# Technical Design: Warranty & Proposal PDF Update

## 1. Architecture Summary
The feature centralizes PDF management for clients into a dedicated screen. It introduces persistence and synchronization for Warranty and Proposal PDFs, allowing them to be shared across devices.
- **Backend**: New `Proposal` model, updated `syncController` to handle `Warranty` and `Proposal` syncing, and updated upload controllers to handle actual file storage.
- **Flutter**: New `PdfManagementScreen` (tabbed), `WarrantyFormScreen` for pre-generation data, updated `DbService` for local metadata storage, and updated `SyncService` for metadata synchronization.

## 2. Backend File Paths

| Path | Action | Description |
| :--- | :--- | :--- |
| `backend/src/models/Proposal.ts` | Create | New model for Proposal PDF metadata. |
| `backend/src/models/index.ts` | Modify | Register `Proposal` model and its association with `Client`. |
| `backend/src/controllers/proposalController.ts` | Create | Controller for uploading, listing, and deleting Proposals. |
| `backend/src/controllers/warrantyController.ts` | Modify | Update `uploadWarranty` to handle actual file uploads and enforce one-warranty rule. |
| `backend/src/controllers/syncController.ts` | Modify | Update `sync` method to include `Warranty` and `Proposal` in changes and updates. |
| `backend/src/routes/proposalRoutes.ts` | Create | Define routes for Proposal operations. |
| `backend/src/routes/warrantyRoutes.ts` | Modify | Update routes for Warranty operations. |
| `backend/src/routes/index.ts` | Modify | Register `proposalRoutes`. |
| `backend/src/app.ts` | Modify | Configure `express.static` to serve the `uploads/` directory. |
| `backend/uploads/.gitkeep` | Create | Ensure the storage directory exists in the repository. |

## 3. Flutter App File Paths

| Path | Action | Description |
| :--- | :--- | :--- |
| `flutter/lib/src/models/warranty.dart` | Modify | Update to include `localId`, `remoteId`, `isDirty`, etc., matching sync patterns. |
| `flutter/lib/src/models/proposal.dart` | Create | New model for Proposal metadata. |
| `flutter/lib/src/services/db_service.dart` | Modify | Add `warranties` and `proposals` tables; add CRUD and dirty fetchers. |
| `flutter/lib/src/services/api_service.dart` | Modify | Update `uploadWarranty` and add `uploadProposal` using multipart requests. |
| `flutter/lib/src/services/sync_service.dart` | Modify | Update `sync` method to include `Warranty` and `Proposal` metadata. |
| `flutter/lib/src/services/pdf_service.dart` | Modify | Update `generateWarrantyPdf` to accept additional dynamic fields from the form. |
| `flutter/lib/src/providers/client_provider.dart` | Modify | Add methods for managing Warranties and Proposals (insert, update, delete, load). |
| `flutter/lib/src/screens/clients/measurement_screen.dart` | Modify | Replace PDF buttons with a single "PDF Management" icon in the AppBar. |
| `flutter/lib/src/screens/clients/pdf_management_screen.dart` | Create | New tabbed screen (Warranty/Proposal) for listing and viewing PDFs. |
| `flutter/lib/src/screens/clients/warranty_form_screen.dart` | Create | Pre-generation editable form for Warranty PDFs. |
| `flutter/lib/src/widgets/pdf_list_item.dart` | Create | Reusable widget for PDF list items in the management screen. |

## 4. Data Model Definitions

### Backend (Sequelize)

**Proposal.ts**
- `id`: `DataTypes.UUID` (Primary Key, defaultValue: `UUIDV4`)
- `clientId`: `DataTypes.UUID` (Foreign Key to `Client`)
- `pdfUrl`: `DataTypes.STRING` (URL/Path to stored file)
- `createdAt`: `DataTypes.DATE`
- `updatedAt`: `DataTypes.DATE`

**Warranty.ts** (Existing update)
- Ensure `pdfUrl` is correctly managed and `clientId` is linked.

### Flutter (SQLite)

**warranties table**
- `local_id`: INTEGER PRIMARY KEY AUTOINCREMENT
- `remote_id`: TEXT UNIQUE
- `client_id`: INTEGER (Foreign Key to `clients.local_id`)
- `warranty_card_number`: TEXT
- `start_date`: TEXT
- `duration_years`: INTEGER
- `pdf_url`: TEXT
- `is_dirty`: INTEGER DEFAULT 1
- `updated_at`: TEXT
- `deleted_at`: TEXT

**proposals table**
- `local_id`: INTEGER PRIMARY KEY AUTOINCREMENT
- `remote_id`: TEXT UNIQUE
- `client_id`: INTEGER (Foreign Key to `clients.local_id`)
- `pdf_url`: TEXT
- `is_dirty`: INTEGER DEFAULT 1
- `updated_at`: TEXT
- `deleted_at`: TEXT

## 5. API Contract

### Syncing
- **Endpoint**: `POST /api/sync`
- **Request `changes` object**: Adds `warranties: Array<any>` and `proposals: Array<any>`.
- **Response `updates` object**: Adds `warranties: Array<any>` and `proposals: Array<any>`.

### Uploads
- **Warranty**: `POST /api/warranty/upload` (Multipart/form-data)
  - Fields: `file` (File), `client_id` (String), `start_date` (String), `duration_years` (Number), `warranty_card_number` (String).
- **Proposal**: `POST /api/proposal/upload` (Multipart/form-data)
  - Fields: `file` (File), `client_id` (String).

### Static Assets
- PDFs will be served from `GET /uploads/:filename`.

## 6. Test Targets
- `backend/src/controllers/syncController.test.ts`: Verify `Warranty` and `Proposal` syncing logic.
- `backend/src/controllers/warrantyController.test.ts`: Test file upload and client ownership validation.
- `backend/src/controllers/proposalController.test.ts`: Test multiple proposal uploads and listing.
- `flutter/test/unit/pdf_service_test.dart`: Test PDF generation with dynamic Warranty fields.
- `flutter/test/unit/sync_service_test.dart`: Test syncing of PDF metadata in Flutter.
- `flutter/test/widgets/pdf_management_screen_test.dart`: Test tab switching and list rendering.

## 7. Verification Plan
1. **Manual Verification**:
   - Open a client's `MeasurementScreen`. Verify the "Generate Proposal" and "Generate Warranty" icons are gone and replaced by a "PDF Management" icon.
   - Open "PDF Management". Verify two tabs: Warranty and Proposal.
   - **Warranty Flow**: Click "Create" -> fill form in `WarrantyFormScreen` -> verify PDF is generated and appears in the list. Verify that trying to create another one prompts for deletion of the existing one.
   - **Proposal Flow**: Click "Create" -> verify PDF is generated instantly and appears in the list. Create multiple proposals and verify they are listed correctly.
   - **Sync Flow**: Perform a sync. Wipe app data and sync again. Verify all PDF metadata is restored.
2. **Automated Verification**:
   - Run `npm run test` for backend.
   - Run `flutter test` for Flutter.

## 8. Import/Path Rules
- **Flutter**: Use relative imports for all local files (e.g., `import '../../models/client.dart';`).
- **Backend**: Use relative imports (e.g., `import { Client } from '../models';`).
- **Naming**: Use `PascalCase` for model classes (e.g., `class Proposal`) and `snake_case` for database fields/JSON keys (e.g., `client_id`).

READY_FOR_TESTS_AND_DEV
