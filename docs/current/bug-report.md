# Bug Report

## Bug 1: Keyboard not appearing for a new row in the item details screen (Regression)

### Steps to Reproduce
1. Navigate to an item details screen.
2. Enter a value in the length input field.
3. Enter a value in the width input field.
4. Tap the "Next" or "Done" key on the soft keyboard.

### Expected Behavior
A new row is added, focus automatically shifts to the first input of the new row, and the soft keyboard remains visible.

### Actual Behavior
A new row appears with the previously entered length and width, but the keyboard dismisses/does not appear for the newly focused row. (Note: This is a regression / not fully fixed from a previous attempt).

### Environment
* Platform: Flutter App (iOS/Android UI)

### Severity / Impact
* Moderate - Disrupts the user's data entry flow, requiring them to manually tap the next field to bring the keyboard back up.

### Evidence
* User reported that previous fix did not resolve the issue.

---

## Bug 2: Sync fails due to empty email validation error

### Steps to Reproduce
1. Have a client record with an empty or missing email address (or other non-required fields).
2. Go to the Sync screen in the app.
3. Press the "Sync Now" button.

### Expected Behavior
The sync process should complete successfully. Empty optional fields (like email) should be accepted or properly handled as `null`/empty strings without failing validation.

### Actual Behavior
Sync fails with the error message: 
`Sync error: ValidationError [SequelizeValidationError]: Validation error: Validation isEmail on email failed`

### Environment
* Backend: Node.js (Sequelize ORM)
* App: Flutter Sync Module

### Severity / Impact
* High - Blocks synchronization entirely for users who have created clients without an email address.

### Evidence
* Error log: `ValidationError [SequelizeValidationError]: Validation error: Validation isEmail on email failed`

---

READY_FOR_BUGFIX
