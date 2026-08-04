import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_provider.dart';
import '../../updates/update_coordinator.dart';
import 'default_prices_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Dark Mode'),
            value: context.watch<ThemeProvider>().isDarkMode,
            onChanged: (_) => context.read<ThemeProvider>().toggleTheme(),
          ),
          ListTile(
            title: const Text('Default Prices'),
            subtitle: const Text('Manage your default pricing list'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const DefaultPricesScreen(),
                ),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.system_update),
            title: const Text('Check for updates'),
            subtitle: const Text('Check the approved release service'),
            onTap: () =>
                context.read<UpdateCoordinator>().checkForUpdates(manual: true),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign Out'),
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                    'Downloaded and unsynced work stays on this device for this account. Other accounts cannot view or sync it.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.of(dialogContext).pop(true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) {
                await context.read<AuthProvider>().logout();
              }
            },
          ),
        ],
      ),
    );
  }
}
