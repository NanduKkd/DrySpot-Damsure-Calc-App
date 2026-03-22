# Flutter: Coding Standards

## Code Style Rules

### General

- Follow `flutter_lints`
- Run `dart format` on every change
- Keep screen widgets focused; move network and transformation logic out of the UI
- Prefer `const` constructors and widgets when values are static

### Dart

- Explicit types for public APIs
- Avoid `dynamic` unless an external package forces it
- Use `final` by default and `const` whenever possible
- Prefer immutable model objects

```dart
class UserProfile {
  const UserProfile({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}
```

### Widgets

- Keep widgets small and composable
- Use `StatefulWidget` only when local mutable state is needed
- Guard async `setState` calls with `mounted`
- Do not perform HTTP calls directly inside `build`

```dart
Future<void> _refresh() async {
  final message = await widget.apiClient.fetchHealth();

  if (!mounted) {
    return;
  }

  setState(() {
    _message = message;
  });
}
```

### Naming Conventions

| Element | Convention | Example |
|---------|------------|---------|
| Files | `snake_case.dart` | `home_screen.dart` |
| Classes | `PascalCase` | `HomeScreen` |
| Private fields | `_camelCase` | `_isLoading` |
| Methods | `camelCase` | `fetchHealth` |
| Constants | `lowerCamelCase` or `kPrefix` | `kPrimarySpacing` |

## File Organization

1. Flutter imports
2. Package imports
3. Internal package imports
4. Class definitions
5. Private helpers

## Performance Rules

- Use `ListView.builder` for long lists
- Avoid rebuilding large subtrees unnecessarily
- Cache network-backed futures when the screen lifecycle allows it
- Keep image sizes appropriate for device usage
