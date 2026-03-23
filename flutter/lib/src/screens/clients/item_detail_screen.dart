import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/item.dart';
import '../../models/rectangle.dart';
import '../../providers/client_provider.dart';
import '../../providers/settings_provider.dart';

class ItemDetailScreen extends StatefulWidget {
  final int itemLocalId;

  const ItemDetailScreen({super.key, required this.itemLocalId});

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  final _priceController = TextEditingController();
  final _newLengthController = TextEditingController();
  final _newWidthController = TextEditingController();
  final _newLengthFocus = FocusNode();
  final _newWidthFocus = FocusNode();

  Item? _item;
  bool _isLoading = true;
  double? _selectedPrice;
  bool _isCustomPrice = false;

  @override
  void initState() {
    super.initState();
    _loadItem();
  }

  Future<void> _loadItem() async {
    final clientProvider = context.read<ClientProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    
    final item = await clientProvider.getItemByLocalId(widget.itemLocalId);
    await settingsProvider.loadSettings();

    if (mounted) {
      setState(() {
        _item = item;
        if (item != null) {
          _priceController.text = item.price.toStringAsFixed(2);
          
          // Determine if it matches a default price
          final defaultPrices = settingsProvider.defaultPrices.where((p) => p.enabled).map((p) => p.price).toList();
          if (defaultPrices.contains(item.price)) {
            _selectedPrice = item.price;
            _isCustomPrice = false;
          } else {
            _selectedPrice = null;
            _isCustomPrice = true;
          }
        }
        _isLoading = false;
      });
      // Request focus after loading
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _newLengthFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _priceController.dispose();
    _newLengthController.dispose();
    _newWidthController.dispose();
    _newLengthFocus.dispose();
    _newWidthFocus.dispose();
    super.dispose();
  }

  Future<void> _updatePrice(double? price) async {
    if (_item == null) return;
    double? newPrice = price;
    newPrice ??= double.tryParse(_priceController.text);

    if (newPrice != null && newPrice != _item!.price) {
      final updatedItem =
          _item!.copyWith(price: newPrice, updatedAt: DateTime.now());
      final clientProvider = context.read<ClientProvider>();
      await clientProvider.updateItem(updatedItem);
      if (mounted) {
        setState(() {
          _item = updatedItem;
          _priceController.text = newPrice!.toStringAsFixed(2);
        });
      }
    }
  }

  Future<void> _submitNewRectangle() async {
    if (_item == null) return;
    final length = double.tryParse(_newLengthController.text);
    final width = double.tryParse(_newWidthController.text);

    if (length != null && width != null && length > 0 && width > 0) {
      final rectangle = Rectangle(
        itemId: _item!.localId!,
        length: length,
        width: width,
      );
      final clientProvider = context.read<ClientProvider>();
      _newLengthFocus.requestFocus();
      await clientProvider.addRectangle(rectangle);
      if (mounted) {
        _newLengthController.clear();
        _newWidthController.clear();
        _loadItem();
      }
    }
  }

  Future<void> _showEditRectangleDialog(Rectangle rect) async {
    final lengthController =
        TextEditingController(text: rect.length.toString());
    final widthController = TextEditingController(text: rect.width.toString());
    final clientProvider = context.read<ClientProvider>();

    final updated = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Rectangle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lengthController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Length'),
              autofocus: true,
            ),
            TextField(
              controller: widthController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Width'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final length = double.tryParse(lengthController.text);
              final width = double.tryParse(widthController.text);
              if (length != null && width != null && length > 0 && width > 0) {
                Navigator.of(context).pop(true);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (updated == true) {
      final length = double.parse(lengthController.text);
      final width = double.parse(widthController.text);
      final updatedRect = rect.copyWith(
        length: length,
        width: width,
        updatedAt: DateTime.now(),
        isDirty: true,
      );
      await clientProvider.updateRectangle(updatedRect);
      if (mounted) {
        _loadItem();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Item Not Found')),
        body: const Center(child: Text('Item not found.')),
      );
    }

    final settingsProvider = context.watch<SettingsProvider>();
    final activeDefaultPrices = settingsProvider.defaultPrices.where((p) => p.enabled).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(_item!.name),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Select Price (₹ per sqft):', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    ...activeDefaultPrices.map((dp) => ChoiceChip(
                      label: Text('₹${dp.price.toStringAsFixed(0)}'),
                      selected: _selectedPrice == dp.price && !_isCustomPrice,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedPrice = dp.price;
                            _isCustomPrice = false;
                          });
                          _updatePrice(dp.price);
                        }
                      },
                    )),
                    ChoiceChip(
                      label: const Text('Custom'),
                      selected: _isCustomPrice,
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedPrice = null;
                            _isCustomPrice = true;
                          });
                        }
                      },
                    ),
                  ],
                ),
                if (_isCustomPrice)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Row(
                      children: [
                        const Text('Custom Price: ₹', style: TextStyle(fontSize: 16)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 100,
                          child: TextField(
                            controller: _priceController,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(isDense: true),
                            onSubmitted: (_) => _updatePrice(null),
                            onTapOutside: (_) => _updatePrice(null),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: _item!.rectangles.length,
              itemBuilder: (context, index) {
                final rect = _item!.rectangles[index];
                return ListTile(
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text('${rect.length} x ${rect.width}'),
                  subtitle: Text('Area: ${(rect.length * rect.width).toStringAsFixed(2)} sqft'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _showEditRectangleDialog(rect),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await context.read<ClientProvider>().deleteRectangle(rect.localId!);
                          _loadItem();
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newLengthController,
                    focusNode: _newLengthFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Length',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => _newWidthFocus.requestFocus(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _newWidthController,
                    focusNode: _newWidthFocus,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Width',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _submitNewRectangle(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
