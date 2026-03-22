# Flutter: API Communication

## HTTP Client Setup

Use a dedicated service class for backend communication.

```dart
import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiClient {
  ApiClient({
    http.Client? client,
    String? baseUrl,
  })  : _client = client ?? http.Client(),
        _baseUrl = baseUrl ??
            const String.fromEnvironment(
              'API_BASE_URL',
              defaultValue: 'http://localhost:3000',
            );

  final http.Client _client;
  final String _baseUrl;

  Future<String> fetchHealth() async {
    final response = await _client.get(Uri.parse('$_baseUrl/health'));

    if (response.statusCode != 200) {
      throw ApiException('Health check failed', response.statusCode);
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return payload['message'] as String;
  }
}

class ApiException implements Exception {
  ApiException(this.message, this.statusCode);

  final String message;
  final int statusCode;
}
```

## Service Pattern

- Keep network code in `lib/src/services/`.
- Decode DTOs there, not in widgets.
- Return typed models or simple domain objects.

## UI Consumption Pattern

Use `FutureBuilder`, controller classes, or a small state layer depending on complexity.

```dart
late Future<String> _statusFuture;

@override
void initState() {
  super.initState();
  _statusFuture = widget.apiClient.fetchHealth();
}
```

## Error Handling

- Convert HTTP failures into typed exceptions.
- Map transport errors to user-facing copy in the screen layer.
- Avoid showing raw stack traces in widgets.

## Environment Configuration

Use `--dart-define` for runtime configuration:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

Common local values:

- Android emulator: `http://10.0.2.2:3000`
- iOS simulator: `http://localhost:3000`
- Physical device: machine LAN IP, for example `http://192.168.1.20:3000`
  const { data: users, isLoading, error, refetch } = useUsers();

  if (isLoading) return <SkeletonLoader />;
  if (error) return <ErrorDisplay message={error.message} onRetry={refetch} />;
  
  return (
    <ul>
      {users?.map((user) => (
        <UserItem key={user.id} user={user} />
      ))}
    </ul>
  );
};
```

## REST API Conventions

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/users` | List users |
| GET | `/users/:id` | Get user by ID |
| POST | `/users` | Create user |
| PUT | `/users/:id` | Update user (full) |
| PATCH | `/users/:id` | Update user (partial) |
| DELETE | `/users/:id` | Delete user |
