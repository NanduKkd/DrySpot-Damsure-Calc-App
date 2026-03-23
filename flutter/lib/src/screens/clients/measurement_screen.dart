import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../models/client.dart';
import '../../models/item.dart';
import '../../providers/client_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/pdf_service.dart';
import '../../services/api_service.dart';
import 'item_detail_screen.dart';

class MeasurementScreen extends StatelessWidget {
  final Client client;
  const MeasurementScreen({super.key, required this.client});

  Future<void> _addItem(BuildContext context) async {
    final nameController = TextEditingController();
    
    final newItemId = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Item'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Name (e.g., Roof)'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final defaultPrice = context.read<SettingsProvider>().firstDefaultPrice;
              final item = Item(
                clientId: client.localId!,
                name: nameController.text,
                price: defaultPrice,
              );
              final id = await context.read<ClientProvider>().addItem(item);
              if (context.mounted) Navigator.pop(context, id);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (newItemId != null && context.mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ItemDetailScreen(itemLocalId: newItemId),
        ),
      );
    }
  }

  Future<void> _toggleItem(BuildContext context, Item item) async {
    await context.read<ClientProvider>().updateItem(item.copyWith(enabled: !item.enabled, updatedAt: DateTime.now()));
  }

  Future<void> _applyBulkPrice(BuildContext context) async {
      final settingsProvider = context.read<SettingsProvider>();
      final clientProvider = context.read<ClientProvider>();
      await settingsProvider.loadSettings();
      if (!context.mounted) return;
      
      double? selectedPrice;
      bool isCustomPrice = false;
      final priceController = TextEditingController();

      await showDialog(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              final activeDefaultPrices = settingsProvider.defaultPrices.where((p) => p.enabled).toList();
              
              return AlertDialog(
                  title: const Text('Bulk Apply Price'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Select Price (₹ per sqft):'),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          children: [
                            ...activeDefaultPrices.map((dp) => ChoiceChip(
                              label: Text('₹${dp.price.toStringAsFixed(0)}'),
                              selected: selectedPrice == dp.price && !isCustomPrice,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    selectedPrice = dp.price;
                                    isCustomPrice = false;
                                  });
                                }
                              },
                            )),
                            ChoiceChip(
                              label: const Text('Custom'),
                              selected: isCustomPrice,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() {
                                    selectedPrice = null;
                                    isCustomPrice = true;
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                        if (isCustomPrice)
                          Padding(
                            padding: const EdgeInsets.only(top: 16.0),
                            child: TextField(
                              controller: priceController,
                              decoration: const InputDecoration(
                                labelText: 'Custom Price',
                                border: OutlineInputBorder(),
                                prefixText: '₹',
                              ),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            ),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      TextButton(
                          onPressed: () async {
                              double finalPrice = 0;
                              if (isCustomPrice) {
                                finalPrice = double.tryParse(priceController.text) ?? 0;
                              } else if (selectedPrice != null) {
                                finalPrice = selectedPrice!;
                              } else {
                                // Nothing selected
                                return;
                              }
                              
                              if (finalPrice > 0) {
                                await clientProvider.applyBulkPrice(client.localId!, finalPrice);
                                if (context.mounted) Navigator.pop(context);
                              }
                          },
                          child: const Text('Apply'),
                      ),
                  ],
              );
            }
          ),
      );
  }

  Future<void> _generatePdf(BuildContext context, Client currentClient) async {
      try {
          final file = await PdfService().generateWarrantyPdf(currentClient, DateTime.now(), 5);
          await Share.shareXFiles([XFile(file.path)], text: 'Warranty for ${currentClient.name}');
          
          // Also upload to API
          if (context.mounted) {
            await context.read<ApiService>().uploadWarranty({
                'client_id': currentClient.remoteId,
                'start_date': DateTime.now().toIso8601String(),
                'duration_years': 5,
            });
          }
      } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
          }
      }
  }

  Future<void> _generateProposal(BuildContext context, Client currentClient) async {
      try {
          final file = await PdfService().generateProposalPdf(currentClient);
          await Share.shareXFiles([XFile(file.path)], text: 'Proposal for ${currentClient.name}');
      } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
          }
      }
  }

  Future<void> _showDiscountDialog(BuildContext context, Client currentClient) async {
      final discountController = TextEditingController(text: currentClient.finalTotalPrice.toStringAsFixed(2));
      
      await showDialog(
          context: context,
          builder: (context) => StatefulBuilder(
            builder: (context, setState) {
              final discountedPrice = double.tryParse(discountController.text) ?? 0;
              final originalPrice = currentClient.originalTotalPrice;
              final discountAmount = originalPrice - discountedPrice;
              final discountPercentage = originalPrice > 0 ? (discountAmount / originalPrice) * 100 : 0;

              return AlertDialog(
                  title: const Text('Apply Discount'),
                  content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                          Text('Original Total: ₹${originalPrice.toStringAsFixed(2)}'),
                          const SizedBox(height: 16),
                          TextField(
                              controller: discountController,
                              decoration: const InputDecoration(
                                  labelText: 'Discounted Price',
                                  border: OutlineInputBorder(),
                                  prefixText: '₹',
                              ),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              autofocus: true,
                              onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 16),
                          Text('Discount Amount: ₹${discountAmount.toStringAsFixed(2)}', 
                               style: TextStyle(color: discountAmount >= 0 ? Colors.green : Colors.red)),
                          Text('Discount Percentage: ${discountPercentage.toStringAsFixed(1)}%',
                               style: TextStyle(color: discountAmount >= 0 ? Colors.green : Colors.red)),
                      ],
                  ),
                  actions: [
                      TextButton(
                          onPressed: () async {
                              final updatedClient = currentClient.copyWith(
                                  clearDiscount: true,
                                  isDirty: true,
                                  updatedAt: DateTime.now(),
                              );
                              await context.read<ClientProvider>().updateClient(updatedClient);
                              if (context.mounted) Navigator.pop(context);
                          },
                          child: const Text('Clear Discount'),
                      ),
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                      TextButton(
                          onPressed: () async {
                              final price = double.tryParse(discountController.text);
                              if (price != null) {
                                  final updatedClient = currentClient.copyWith(
                                      discountedPrice: price,
                                      isDirty: true,
                                      updatedAt: DateTime.now(),
                                  );
                                  await context.read<ClientProvider>().updateClient(updatedClient);
                                  if (context.mounted) Navigator.pop(context);
                              }
                          },
                          child: const Text('Save'),
                      ),
                  ],
              );
            }
          ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClientProvider>(
      builder: (context, provider, _) {
        final currentClient = provider.clients.firstWhere((c) => c.localId == client.localId, orElse: () => client);
        return Scaffold(
          appBar: AppBar(
            title: Text('${currentClient.name} Measurements'),
            actions: [
                IconButton(
                  tooltip: 'Bulk Apply Price',
                  icon: const Icon(Icons.price_check), 
                  onPressed: () => _applyBulkPrice(context)
                ),
                IconButton(
                  tooltip: 'Generate Proposal',
                  icon: const Icon(Icons.description), 
                  onPressed: () => _generateProposal(context, currentClient)
                ),
                IconButton(
                  tooltip: 'Generate Warranty',
                  icon: const Icon(Icons.picture_as_pdf), 
                  onPressed: () => _generatePdf(context, currentClient)
                ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              Text('Total Area: ${currentClient.totalArea.toStringAsFixed(2)} sqft', style: Theme.of(context).textTheme.titleLarge),
                              if (currentClient.discountedPrice != null) ...[
                                Text(
                                  'Original: ₹${currentClient.originalTotalPrice.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                    color: Colors.grey,
                                    fontSize: 14,
                                  ),
                                ),
                                Text(
                                  'Discounted: ₹${currentClient.discountedPrice!.toStringAsFixed(2)}',
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ] else ...[
                                Text('Total Price: ₹${currentClient.originalTotalPrice.toStringAsFixed(2)}', style: Theme.of(context).textTheme.titleMedium),
                              ],
                          ]
                      ),
                    ),
                    Column(
                      children: [
                        ElevatedButton(onPressed: () => _addItem(context), child: const Text('Add Item')),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          onPressed: () => _showDiscountDialog(context, currentClient),
                          icon: const Icon(Icons.local_offer, size: 16),
                          label: const Text('Discount'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: currentClient.items.length,
                  itemBuilder: (context, index) {
                    final item = currentClient.items[index];
                    return ListTile(
                      leading: Checkbox(
                        value: item.enabled,
                        onChanged: (_) => _toggleItem(context, item),
                      ),
                      title: Text('${item.name} (${item.area.toStringAsFixed(2)} sqft)'),
                      subtitle: Text('Price: ₹${item.price.toStringAsFixed(2)} | Total: ₹${item.totalPrice.toStringAsFixed(2)}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ItemDetailScreen(itemLocalId: item.localId!),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      }
    );
  }
}
