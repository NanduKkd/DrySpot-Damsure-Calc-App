import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/sync_provider.dart';
import '../../providers/client_provider.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Sync')),
      body: Consumer<SyncProvider>(
        builder: (context, syncProvider, _) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (syncProvider.isSyncing)
                  const CircularProgressIndicator()
                else ...[
                  const Icon(Icons.sync, size: 100, color: Colors.blue),
                  const SizedBox(height: 20),
                  Text(
                    'Last Sync: ${syncProvider.lastSyncTime ?? "Never"}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (syncProvider.error != null)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        'Error: ${syncProvider.error}',
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 40),
                  ElevatedButton.icon(
                    onPressed: () async {
                      await syncProvider.sync();
                      if (context.mounted) {
                        context.read<ClientProvider>().loadClients();
                      }
                    },
                    icon: const Icon(Icons.cloud_upload),
                    label: const Text('Sync Now'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
