# Test Plan: Bug Batch

## 1. Keyboard Dismissal on New Row Creation (Regression)
- **Target:** `flutter/lib/src/screens/clients/item_detail_screen.dart`
- **Test file:** `flutter/test/widgets/item_detail_keyboard_bug_test.dart`
- **Goal:** Verify that focus is maintained/requested correctly on the `Length` text field after a new rectangle is submitted. Due to Flutter widget testing limitations on system keyboard behavior when widgets lose their tree position, the test will assert that the `FocusNode` itself retains `hasFocus`. However, to fix the actual device behavior, the entry row must either be given a `Key` or pulled out of the `ListView.builder` to prevent unmounting during index changes.
- **Commands:** `cd flutter && flutter test test/widgets/item_detail_keyboard_bug_test.dart`

## 2. Sync fails due to empty email validation error
- **Target:** `backend/src/models/Client.ts` / `backend/src/controllers/syncController.ts`
- **Test file:** `backend/src/controllers/syncController_email.test.ts`
- **Goal:** Verify that syncing a client with an empty string `""` for the `email` field does not trigger a `SequelizeValidationError` (specifically `isEmail` validation). The sync process should succeed and accept the empty value or treat it as `null`.
- **Commands:** `cd backend && npm test -- src/controllers/syncController_email.test.ts`
