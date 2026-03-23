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
