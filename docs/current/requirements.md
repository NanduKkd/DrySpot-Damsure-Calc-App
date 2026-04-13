# Warranty & Proposal PDF Update

## 1. Feature Summary
The client wants to update how Warranty and Proposal PDFs are generated and managed. 
Currently, PDFs are generated instantly and shared without being stored in the database or synchronized with the backend. 
This feature will introduce a pre-generation form for Warranty PDFs to allow editing dynamic fields. It will also add a dedicated PDF Management screen accessible from the Client Details (`MeasurementScreen`), replacing the existing generation buttons. Both Warranty and Proposal PDFs will be uploaded to the backend and synced locally so they persist across devices.

## 2. In Scope
- Creating a pre-generation editable form for Warranty PDFs.
- Creating a new PDF Management screen with two tabs: "Warranty" and "Proposal".
- Adding an entry point (icon) to the PDF Management screen from the `MeasurementScreen` AppBar.
- Removing the existing "Generate Proposal" and "Generate Warranty" buttons from the `MeasurementScreen`.
- Implementing UI in the PDF Management screen to list, view, create, and delete PDFs for both tabs.
- Restricting Warranty PDFs to a maximum of one per client (deleting the old one before creating a new one requires user confirmation).
- Allowing multiple Proposal PDFs per client.
- Modifying the local SQLite database (`DbService`) to store Proposal and Warranty metadata (including the PDF URL/path).
- Updating the backend models/database to support Proposals (Warranties already exist but need syncing logic).
- Implementing file upload for the generated PDFs to the backend.
- Updating the synchronization logic (`syncController.ts` on backend, `SyncProvider` in Flutter) to include Proposals and Warranties.

## 3. Out of Scope
- Changes to the actual design or layout of the generated PDF documents.
- Any other client details modifications not related to PDF generation or syncing.
- Offline PDF generation if the required assets/fonts are not already cached.

## 4. User Flows
1. **Navigating to PDF Management:**
   - User opens a Client's details (`MeasurementScreen`).
   - User taps the new "PDF Management" icon in the AppBar.
   - User is presented with a screen containing two tabs: "Warranty" and "Proposal".

2. **Managing Warranty PDFs:**
   - User navigates to the "Warranty" tab.
   - If a warranty exists, it is displayed. The user can view or delete it.
   - If no warranty exists, the user taps "Create".
   - A form appears pre-filled with the client's data (e.g., name, address). The user can edit these fields. Note: Editing these fields *only* affects the generated PDF, not the core client data in the database.
   - User confirms the form. The PDF is generated, uploaded to the backend, saved locally, and appears in the list.
   - If a user tries to create a new warranty when one already exists, they are prompted to delete the existing one first (with confirmation).

3. **Managing Proposal PDFs:**
   - User navigates to the "Proposal" tab.
   - A list of existing proposals is displayed. The user can view or delete any of them.
   - User taps "Create". (No pre-generation form is needed for proposals).
   - The PDF is generated, uploaded to the backend, saved locally, and appears in the list.

4. **Synchronization:**
   - When the user triggers a sync (or background sync occurs), any newly created or deleted Proposals/Warranties are synced with the backend, ensuring the PDF URLs are available across devices.

## 5. Validation and Error Handling Rules
- Ensure the user confirms before permanently deleting a Warranty or Proposal PDF.
- Handle upload failures gracefully (e.g., allow retry or queue for later sync).
- Validate the pre-generation form for Warranty to ensure required fields are not empty before generating the PDF.

## 6. Non-functional Requirements
- The PDF Management screen should be responsive and match the existing app theme.
- PDF generation should not block the main UI thread.
- Syncing of large PDF files should be optimized (e.g., using background uploads if necessary, though direct upload on creation is preferred).

## 7. Acceptance Criteria
- [ ] The `MeasurementScreen` has a single icon for PDF Management, replacing the old generation buttons.
- [ ] The PDF Management screen has working tabs for Warranty and Proposal.
- [ ] Users can generate a Proposal PDF without a form, and it appears in the list.
- [ ] Users can generate a Warranty PDF *after* filling out an editable form, and it appears in the list.
- [ ] Users can view and delete generated PDFs from the list.
- [ ] The app prevents generating a second Warranty PDF without deleting the first (with confirmation).
- [ ] Generated PDFs are uploaded to the backend.
- [ ] Proposal and Warranty metadata (including PDF URLs) are synchronized via the app's standard sync mechanism.

## 8. Open Assumptions
- The backend will use the existing (or slightly modified) upload endpoint for both Warranty and Proposal PDFs.
- The dummy URL currently used in `warrantyController.ts` for PDF uploads will need to be replaced with actual file storage logic (e.g., local file system or a cloud provider like S3, depending on the backend's current capabilities). For this feature, we assume the backend will handle the physical storage and return a valid URL.
- The `SyncProvider` will be updated to handle file downloads/caching if a user logs into a new device and needs to view a previously generated PDF.

READY_FOR_IMPLEMENTATION
