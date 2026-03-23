import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/settings_provider.dart';

class DefaultPricesScreen extends StatelessWidget {
  const DefaultPricesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Default Prices'),
      ),
      body: Consumer<SettingsProvider>(
        builder: (context, settings, child) {
          final prices = settings.defaultPrices;
          return ListView.builder(
            itemCount: prices.length,
            itemBuilder: (context, index) {
              final dp = prices[index];
              return ListTile(
                title: Text('₹${dp.price.toStringAsFixed(2)}'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: dp.enabled,
                      onChanged: (value) {
                        settings.updateDefaultPrice(dp.copyWith(enabled: value));
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: () {
                        settings.deleteDefaultPrice(dp.localId!);
                      },
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddPriceDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showAddPriceDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Default Price'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Price'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final price = double.tryParse(controller.text);
              if (price != null) {
                context.read<SettingsProvider>().addDefaultPrice(price);
                Navigator.pop(context);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
