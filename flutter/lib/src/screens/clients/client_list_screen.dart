import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/client_provider.dart';
import '../../models/client.dart';
import 'client_form_screen.dart';
import 'measurement_screen.dart';
import '../sync/sync_screen.dart';
import '../settings/settings_screen.dart';

class ClientListScreen extends StatefulWidget {
  const ClientListScreen({super.key});

  @override
  State<ClientListScreen> createState() => _ClientListScreenState();
}

class _ClientListScreenState extends State<ClientListScreen> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clients'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SyncScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Consumer<ClientProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          final filteredClients = _filterClients(provider.clients);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                  decoration: InputDecoration(
                    hintText: 'Search by name or phone',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.trim().isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() {
                                _searchQuery = '';
                              });
                            },
                          )
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              Expanded(
                child: filteredClients.isEmpty
                    ? Center(
                        child: Text(
                          provider.clients.isEmpty
                              ? 'No clients found. Add one!'
                              : 'No clients match your search.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: filteredClients.length,
                        itemBuilder: (context, index) {
                          final client = filteredClients[index];
                          return ListTile(
                            leading: CircleAvatar(
                              child: Text('${index + 1}'),
                            ),
                            title: Text(client.name),
                            subtitle: Text(
                              '${client.totalArea.toStringAsFixed(2)} sqft | ₹${client.finalTotalPrice.toStringAsFixed(2)}',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MeasurementScreen(client: client),
                              ),
                            ),
                            onLongPress: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ClientFormScreen(client: client),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const ClientFormScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }

  List<Client> _filterClients(List<Client> clients) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return clients;
    }

    final queryDigits = _onlyDigits(query);

    return clients.where((client) {
      final name = client.name.toLowerCase();
      final phone = (client.phone ?? '').toLowerCase();
      final phoneDigits = _onlyDigits(phone);

      final nameMatches = name.contains(query);
      final phoneMatches = phone.contains(query) ||
          (queryDigits.isNotEmpty && phoneDigits.contains(queryDigits));

      return nameMatches || phoneMatches;
    }).toList();
  }

  String _onlyDigits(String input) {
    return input.replaceAll(RegExp(r'[^0-9]'), '');
  }
}
