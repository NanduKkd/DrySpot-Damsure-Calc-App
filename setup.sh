#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
FLUTTER_DIR="$PROJECT_ROOT/flutter"
BACKEND_DIR="$PROJECT_ROOT/backend"
DOCS_DIR="$PROJECT_ROOT/docs/current"

echo "========================================"
echo "Project Setup Script"
echo "========================================"

require_command() {
	local command_name="$1"

	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "Required command not found: $command_name"
		exit 1
	fi
}

setup_flutter() {
	echo ""
	echo "Setting up Flutter app..."

	require_command flutter

	mkdir -p "$DOCS_DIR"

	if [ ! -f "$FLUTTER_DIR/pubspec.yaml" ]; then
		echo "Creating Flutter project shell..."
		flutter create --project-name app_client --org com.example.orchestrator "$FLUTTER_DIR"
	else
		echo "Flutter project already exists. Reusing existing directory."
	fi

	mkdir -p "$FLUTTER_DIR/lib/src/screens"
	mkdir -p "$FLUTTER_DIR/lib/src/services"
	mkdir -p "$FLUTTER_DIR/test"
	mkdir -p "$FLUTTER_DIR/integration_test"

	cat > "$FLUTTER_DIR/pubspec.yaml" << 'EOF'
name: app_client
description: Flutter client app for the orchestrator template.
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: '>=3.3.0 <4.0.0'

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  http: ^1.2.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:
    sdk: flutter
  flutter_lints: ^4.0.0

flutter:
  uses-material-design: true
EOF

	cat > "$FLUTTER_DIR/analysis_options.yaml" << 'EOF'
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    prefer_const_constructors: true
    prefer_const_literals_to_create_immutables: true
EOF

	cat > "$FLUTTER_DIR/lib/main.dart" << 'EOF'
import 'package:app_client/src/app.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const App());
}
EOF

	cat > "$FLUTTER_DIR/lib/src/app.dart" << 'EOF'
import 'package:app_client/src/screens/home_screen.dart';
import 'package:app_client/src/services/api_client.dart';
import 'package:flutter/material.dart';

class App extends StatelessWidget {
  const App({
    super.key,
    this.apiClient,
  });

  final ApiClient? apiClient;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter + Node Template',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: HomeScreen(
        apiClient: apiClient ?? ApiClient(),
      ),
    );
  }
}
EOF

	cat > "$FLUTTER_DIR/lib/src/screens/home_screen.dart" << 'EOF'
import 'package:app_client/src/services/api_client.dart';
import 'package:flutter/material.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.apiClient,
  });

  final ApiClient apiClient;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<String> _statusFuture;

  @override
  void initState() {
    super.initState();
    _statusFuture = widget.apiClient.fetchHealth();
  }

  void _reload() {
    setState(() {
      _statusFuture = widget.apiClient.fetchHealth();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter + Node Template'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Backend status',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<String>(
                future: _statusFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const CircularProgressIndicator();
                  }

                  if (snapshot.hasError) {
                    return Text(
                      'Could not reach backend: ${snapshot.error}',
                      textAlign: TextAlign.center,
                    );
                  }

                  return Text(
                    snapshot.data ?? 'No response received.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  );
                },
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _reload,
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
EOF

	cat > "$FLUTTER_DIR/lib/src/services/api_client.dart" << 'EOF'
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
      throw ApiException(
        message: 'Health check failed',
        statusCode: response.statusCode,
      );
    }

    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return payload['message'] as String;
  }
}

class ApiException implements Exception {
  const ApiException({
    required this.message,
    required this.statusCode,
  });

  final String message;
  final int statusCode;

  @override
  String toString() {
    return '$message ($statusCode)';
  }
}
EOF

	cat > "$FLUTTER_DIR/test/widget_test.dart" << 'EOF'
import 'package:app_client/src/app.dart';
import 'package:app_client/src/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApiClient extends ApiClient {
  FakeApiClient(this.message);

  final String message;

  @override
  Future<String> fetchHealth() async {
    return message;
  }
}

void main() {
  testWidgets('renders the backend health message', (tester) async {
    await tester.pumpWidget(
      App(
        apiClient: FakeApiClient('API is running'),
      ),
    );

    expect(find.text('Flutter + Node Template'), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('API is running'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });
}
EOF

	cat > "$FLUTTER_DIR/integration_test/app_test.dart" << 'EOF'
import 'package:app_client/src/app.dart';
import 'package:app_client/src/services/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class FakeApiClient extends ApiClient {
  FakeApiClient(this.message);

  final String message;

  @override
  Future<String> fetchHealth() async {
    return message;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows the starter screen', (tester) async {
    await tester.pumpWidget(
      App(
        apiClient: FakeApiClient('API is running'),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Flutter + Node Template'), findsOneWidget);
    expect(find.text('API is running'), findsOneWidget);
  });
}
EOF

	echo "Installing Flutter packages..."
	if ! (cd "$FLUTTER_DIR" && flutter pub get); then
		echo "flutter pub get failed. Run it manually inside flutter/ after toolchain setup."
	fi
}

setup_backend() {
	echo ""
	echo "Setting up backend..."

	require_command npm

	mkdir -p "$BACKEND_DIR/src"
	mkdir -p "$BACKEND_DIR/tests/integration"
	mkdir -p "$BACKEND_DIR/tests/fixtures"

	cat > "$BACKEND_DIR/package.json" << 'EOF'
{
  "name": "backend",
  "version": "1.0.0",
  "main": "dist/server.js",
  "scripts": {
    "dev": "nodemon src/server.ts",
    "dev:debug": "nodemon --inspect src/server.ts",
    "build": "tsc",
    "verify": "npm run lint && npm test -- --runInBand && npm run build",
    "start": "node dist/server.js",
    "lint": "eslint .",
    "lint:fix": "eslint . --fix",
    "format": "prettier --write \"src/**/*.ts\"",
    "test": "jest",
    "test:watch": "jest --watch",
    "test:coverage": "jest --coverage",
    "test:unit": "jest --testPathPattern=src/",
    "test:integration": "jest --testPathPattern=tests/integration",
    "db:migrate": "sequelize-cli db:migrate",
    "db:seed": "sequelize-cli db:seed:all"
  },
  "dependencies": {
    "bcrypt": "^5.1.0",
    "cors": "^2.8.5",
    "dotenv": "^16.3.0",
    "express": "^4.18.0",
    "express-validator": "^7.0.0",
    "helmet": "^7.1.0",
    "jsonwebtoken": "^9.0.0",
    "morgan": "^1.10.0",
    "pg": "^8.11.0",
    "pg-hstore": "^2.3.4",
    "sequelize": "^6.35.0"
  },
  "devDependencies": {
    "@types/bcrypt": "^5.0.0",
    "@types/cors": "^2.8.0",
    "@types/express": "^4.17.0",
    "@types/jest": "^29.5.0",
    "@types/jsonwebtoken": "^9.0.0",
    "@types/morgan": "^1.9.0",
    "@types/node": "^20.10.0",
    "@types/supertest": "^6.0.0",
    "@typescript-eslint/eslint-plugin": "^6.0.0",
    "@typescript-eslint/parser": "^6.0.0",
    "eslint": "^8.56.0",
    "jest": "^29.7.0",
    "nodemon": "^3.0.0",
    "prettier": "^3.1.0",
    "sequelize-cli": "^6.6.0",
    "supertest": "^6.3.0",
    "ts-jest": "^29.1.0",
    "ts-node": "^10.9.0",
    "typescript": "^5.3.0"
  }
}
EOF

	cat > "$BACKEND_DIR/tsconfig.json" << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "lib": ["ES2020"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "moduleResolution": "node",
    "baseUrl": ".",
    "paths": {
      "@/*": ["src/*"]
    }
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

	cat > "$BACKEND_DIR/eslint.config.js" << 'EOF'
import tseslint from '@typescript-eslint/eslint-plugin';
import tsparser from '@typescript-eslint/parser';

export default [
  {
    files: ['**/*.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: {
        ecmaVersion: 2020,
        sourceType: 'module'
      },
      globals: {
        console: 'readonly',
        process: 'readonly',
        Buffer: 'readonly',
        __dirname: 'readonly',
        module: 'readonly',
        require: 'readonly',
        exports: 'readonly'
      }
    },
    plugins: {
      '@typescript-eslint': tseslint
    },
    rules: {
      ...tseslint.configs.recommended.rules,
      '@typescript-eslint/no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/no-explicit-any': 'warn',
      'max-lines': ['warn', { max: 300, skipBlankLines: true, skipComments: true }],
      'no-console': process.env.NODE_ENV === 'production' ? 'error' : 'warn'
    }
  },
  {
    files: ['**/*.{test,spec}.ts'],
    languageOptions: {
      globals: {
        describe: 'readonly',
        it: 'readonly',
        test: 'readonly',
        expect: 'readonly',
        beforeEach: 'readonly',
        afterEach: 'readonly',
        beforeAll: 'readonly',
        afterAll: 'readonly',
        jest: 'readonly'
      }
    }
  },
  {
    ignores: ['dist', 'node_modules']
  }
];
EOF

	cat > "$BACKEND_DIR/.prettierrc" << 'EOF'
{
  "tabWidth": 4,
  "useTabs": true,
  "semi": true,
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "bracketSpacing": true,
  "arrowParens": "always"
}
EOF

	cat > "$BACKEND_DIR/.env" << 'EOF'
PORT=3000
NODE_ENV=development

DB_HOST=localhost
DB_PORT=5432
DB_NAME=myapp_dev
DB_USER=postgres
DB_PASSWORD=secret
DB_POOL_MIN=2
DB_POOL_MAX=10

JWT_SECRET=your-super-secret-jwt-key-change-in-production
JWT_EXPIRES_IN=7d
EOF

	cat > "$BACKEND_DIR/src/server.ts" << 'EOF'
import app from './app';

const port = process.env.PORT || 3000;

app.listen(port, () => {
  console.log(`Server running on port ${port}`);
});
EOF

	cat > "$BACKEND_DIR/src/app.ts" << 'EOF'
import cors from 'cors';
import express, { Application, NextFunction, Request, Response } from 'express';
import helmet from 'helmet';
import morgan from 'morgan';

const app: Application = express();

app.use(helmet());
app.use(cors());
app.use(morgan('dev'));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.get('/health', (_req: Request, res: Response) => {
  res.json({ message: 'API is running' });
});

app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  console.error(err.stack);
  res.status(500).json({ error: 'Something went wrong!' });
});

export default app;
EOF

	cat > "$BACKEND_DIR/jest.config.js" << 'EOF'
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/src', '<rootDir>/tests'],
  testMatch: ['**/*.test.ts'],
  collectCoverageFrom: ['src/**/*.ts', '!src/**/*.d.ts'],
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'json', 'html'],
  moduleNameMapper: {
    '^@/(.*)$': '<rootDir>/src/$1'
  },
  setupFilesAfterEnv: ['<rootDir>/tests/setup.ts'],
  verbose: true
};
EOF

	cat > "$BACKEND_DIR/tests/setup.ts" << 'EOF'
afterAll(() => {
  jest.restoreAllMocks();
});

afterEach(() => {
  jest.clearAllMocks();
});
EOF

	cat > "$BACKEND_DIR/src/app.test.ts" << 'EOF'
import request from 'supertest';
import app from './app';

describe('app', () => {
  it('responds on the health route', async () => {
    const response = await request(app).get('/health');

    expect(response.status).toBe(200);
    expect(response.body).toEqual({ message: 'API is running' });
  });
});
EOF

	echo "Installing backend dependencies..."
	if ! (cd "$BACKEND_DIR" && npm install); then
		echo "npm install failed. Run it manually inside backend/ when network access is available."
	fi
}

echo ""
echo "Preparing project directories..."
mkdir -p "$DOCS_DIR"

setup_flutter
setup_backend

echo ""
echo "========================================"
echo "Setup Complete!"
echo "========================================"
echo ""
echo "Project structure created:"
echo "  - flutter/      (Flutter + Dart)"
echo "  - backend/      (Node.js + Express + TypeScript)"
echo ""
echo "To start development:"
echo "  npm run dev"
echo ""
echo "If you need a specific simulator or emulator:"
echo "  FLUTTER_DEVICE=<device-id> npm run dev"
echo ""
echo "If the backend is not reachable from Android emulator, run Flutter with:"
echo "  cd flutter && flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000"
