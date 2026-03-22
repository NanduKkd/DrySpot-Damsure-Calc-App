# Flutter: Project Structure

## Overview

This document describes the preferred project structure for the Flutter application.

## Root Level

```text
flutter/
├── android/                 # Android platform project
├── ios/                     # iOS platform project
├── lib/                     # Dart source
├── test/                    # Unit and widget tests
├── integration_test/        # Integration tests
├── pubspec.yaml             # Dependencies and scripts
├── pubspec.lock             # Locked dependency versions
└── analysis_options.yaml    # Lint rules
```

## Application Code (`lib/`)

```text
lib/
├── main.dart                # Entry point
└── src/
    ├── app.dart             # MaterialApp setup
    ├── screens/             # Route destinations
    ├── widgets/             # Shared widgets
    ├── services/            # API clients and repositories
    ├── models/              # DTOs and domain models
    ├── state/               # ChangeNotifiers / controllers
    ├── theme/               # ThemeData and design tokens
    └── utils/               # Formatting and shared helpers
```

## Feature-Oriented Layout

For larger apps, group by feature under `lib/src/features/`:

```text
features/
├── auth/
│   ├── data/
│   ├── presentation/
│   └── widgets/
├── dashboard/
└── profile/
```

## Test Directories

```text
test/
├── widgets/
├── services/
└── utils/

integration_test/
└── app_test.dart
```

## File Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Dart files | `snake_case.dart` | `profile_screen.dart` |
| Widgets/classes | `PascalCase` | `ProfileScreen` |
| Private members | `_leadingUnderscore` | `_loadProfile` |
| Tests | `<subject>_test.dart` | `api_client_test.dart` |

## Import Order

```dart
// 1. Flutter SDK
import 'package:flutter/material.dart';

// 2. External packages
import 'package:http/http.dart' as http;

// 3. Internal package imports
import 'package:app_client/src/services/api_client.dart';

// 4. Relative imports for local siblings
import 'widgets/status_card.dart';
```
