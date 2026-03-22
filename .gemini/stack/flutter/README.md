# Flutter Stack

## Overview

The client app is built with Flutter and Dart. Use standard Flutter project structure first, then add feature modules only when the app genuinely needs them.

## Technology Choices

### Core
- **Flutter** 3.x
- **Dart** 3.x
- **Material 3** for default UI patterns

### State Management
- **Stateful widgets** for screen-local state
- **ChangeNotifier / ValueNotifier** for lightweight shared state
- **Riverpod** only when the app grows beyond simple local patterns

### Routing
- **Navigator 2.0 / go_router** when multiple flows exist
- **Navigator** directly for small apps

### Networking
- **`http`** for straightforward REST APIs
- **`dio`** when interceptors, retries, or upload progress become important

### Testing
- **`flutter test`** for unit and widget tests
- **`integration_test`** for end-to-end mobile flows

## Directory Structure

```text
flutter/
├── android/                 # Android runner
├── ios/                     # iOS runner
├── lib/
│   ├── main.dart            # App entry point
│   └── src/
│       ├── app.dart         # MaterialApp wiring
│       ├── screens/         # Screen widgets
│       ├── services/        # API clients and repositories
│       ├── models/          # Data models
│       ├── widgets/         # Reusable widgets
│       └── theme/           # Theme configuration
├── test/                    # Unit + widget tests
├── integration_test/        # Integration tests
├── pubspec.yaml
└── analysis_options.yaml
```

## Key Conventions

### File Naming
- Dart files: `snake_case.dart`
- Classes and widgets: `PascalCase`
- Private members: `_leadingUnderscore`
- Test files: `<subject>_test.dart`

### Widget Structure

```dart
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isLoading = false;

  Future<void> _loadProfile() async {
    setState(() => _isLoading = true);

    try {
      // fetch data
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _isLoading ? const CircularProgressIndicator() : const SizedBox.shrink(),
    );
  }
}
```

### Import Conventions
- Prefer `package:` imports within the Flutter app.
- Keep relative imports only for files in the same feature folder.
- Avoid deep cross-feature imports.

## Development Workflow

### Starting Development
```bash
cd flutter
flutter pub get
flutter run
```

### Running Tests
```bash
flutter test
flutter test integration_test
```

### Linting & Formatting
```bash
flutter analyze
dart format lib test integration_test
```

## See Also

- [Project Structure](./project-structure.md)
- [Coding Standards](./coding-standards.md)
- [API Communication](./api-communication.md)
