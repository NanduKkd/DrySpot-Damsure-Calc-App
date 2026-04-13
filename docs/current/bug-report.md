# Bug Report

## 1. Bug Title
Sync Failure: NoSuchMethodError calling `toDouble` on String

## 2. Steps to reproduce
1. Ensure there is existing data containing decimal/numerical values stored as strings (e.g., "60.00") in the backend database.
2. Log into the app on the emulator.
3. Navigate to the "Sync" page.
4. Press the "Sync now" button.

## 3. Expected behavior
The synchronization should complete successfully, and all data from the database should be visible on the phone.

## 4. Actual behavior
The sync process fails with the following error message:
`Error: NoSuchMethodError: Class String has no instance methof toDouble. Receiver: "60.00"`

## 5. Environment
- **Device/Platform:** Android Emulator

## 6. Severity / impact
High - Prevents data synchronization from the backend to the mobile app, blocking core data retrieval functionality.

## 7. Evidence or missing evidence
- Error trace: `Error: NoSuchMethodError: Class String has no instance methof toDouble. Receiver: "60.00"`
- Note for developer: Indicates a Dart type parsing issue. A string value is receiving a `.toDouble()` call, which doesn't exist on the `String` class. `double.parse()` or `double.tryParse()` should likely be used instead.

READY_FOR_BUGFIX
