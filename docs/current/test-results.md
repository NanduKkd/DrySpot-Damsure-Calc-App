# Test Results: Bug Batch

## 1. Keyboard Dismissal on New Row Creation (Regression)
- **Command:** `cd flutter && flutter test test/widgets/item_detail_keyboard_bug_test.dart`
- **Status:** **PASS** (in widget tests)
- **Notes:** The widget test passes because `testWidgets` does not simulate the system keyboard dismissal when a widget loses its tree position (which happens when inserting a new `ListTile` pushes the entry `TextField` to index `N+1` without a `Key`). The `FocusNode.hasFocus` remains true in tests, but detaching unkeyed `TextFields` from the element tree causes actual devices to dismiss the soft keyboard. 
- **Developer Action:** The Developer needs to ensure the "New Entry Row" is either wrapped with a unique `Key` or pulled entirely out of the `ListView.builder` (e.g., as the last child of a parent `Column`) to prevent unmounting and subsequent keyboard dismissal.

## 2. Sync fails due to empty email validation error
- **Command:** `cd backend && npm test -- src/controllers/syncController_email.test.ts`
- **Status:** **FAIL**
- **Notes:** The test successfully reproduces the bug. Sending a client update with `email: ""` throws a 500 server error because of `SequelizeValidationError: Validation isEmail on email failed`.
- **Developer Action:** The Developer needs to update the backend validation or sync logic to allow empty strings `""` for the `email` field (e.g., by converting `""` to `null` before upserting, or changing the model definition to allow empty strings).

---

`READY_FOR_DEV`
