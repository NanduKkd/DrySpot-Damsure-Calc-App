import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/item.dart';
import '../../models/rectangle.dart';
import '../../providers/client_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/rectangle_image_service.dart';

class ItemDetailScreen extends StatefulWidget {
  final int itemLocalId;
  final RectangleImageService? rectangleImageService;

  const ItemDetailScreen({
    super.key,
    required this.itemLocalId,
    this.rectangleImageService,
  });

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  final _priceController = TextEditingController();
  final _newLengthController = TextEditingController();
  final _newWidthController = TextEditingController();
  final _newLengthFocus = FocusNode();
  final _newWidthFocus = FocusNode();

  late final RectangleImageService _rectangleImageService;

  Item? _item;
  bool _isLoading = true;
  bool _isProcessingImage = false;
  double? _selectedPrice;
  bool _isCustomPrice = false;
  String? _pendingRectangleImageData;

  @override
  void initState() {
    super.initState();
    _rectangleImageService =
        widget.rectangleImageService ?? RectangleImageService();
    _loadItem();
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

  Future<void> _loadItem() async {
    final clientProvider = context.read<ClientProvider>();
    final settingsProvider = context.read<SettingsProvider>();

    final item = await clientProvider.getItemByLocalId(widget.itemLocalId);
    await settingsProvider.loadSettings();

    if (!mounted) return;

    setState(() {
      _item = item;
      if (item != null) {
        _priceController.text = item.price.toStringAsFixed(2);

        final defaultPrices = settingsProvider.defaultPrices
            .where((p) => p.enabled)
            .map((p) => p.price)
            .toList();
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _newLengthFocus.requestFocus();
      }
    });
  }

  Future<void> _updatePrice(double? price) async {
    if (_item == null) return;

    double? newPrice = price;
    newPrice ??= double.tryParse(_priceController.text);

    if (newPrice != null && newPrice != _item!.price) {
      final updatedItem =
          _item!.copyWith(price: newPrice, updatedAt: DateTime.now());
      await context.read<ClientProvider>().updateItem(updatedItem);

      if (!mounted) return;
      setState(() {
        _item = updatedItem;
        _priceController.text = newPrice!.toStringAsFixed(2);
      });
    }
  }

  Future<void> _submitNewRectangle() async {
    if (_item == null) return;

    final length = double.tryParse(_newLengthController.text);
    final width = double.tryParse(_newWidthController.text);

    if (length == null || width == null || length <= 0 || width <= 0) {
      return;
    }

    final rectangle = Rectangle(
      itemId: _item!.localId!,
      length: length,
      width: width,
      imageData: _pendingRectangleImageData,
    );

    _newLengthFocus.requestFocus();
    await context.read<ClientProvider>().addRectangle(rectangle);

    if (!mounted) return;
    setState(() {
      _newLengthController.clear();
      _newWidthController.clear();
      _pendingRectangleImageData = null;
    });
    await _loadItem();
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

    if (updated != true) return;

    final updatedRect = rect.copyWith(
      length: double.parse(lengthController.text),
      width: double.parse(widthController.text),
      updatedAt: DateTime.now(),
      isDirty: true,
    );
    await clientProvider.updateRectangle(updatedRect);

    if (mounted) {
      await _loadItem();
    }
  }

  Future<void> _showImageSourceOptions({
    required Future<void> Function(ImageSource source) onSelectSource,
    Future<void> Function()? onRemove,
  }) async {
    if (_isProcessingImage) return;

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('Take Photo'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await onSelectSource(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Upload From Gallery'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await onSelectSource(ImageSource.gallery);
                },
              ),
              if (onRemove != null)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text(
                    'Remove Image',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await onRemove();
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _setPendingRectangleImage(ImageSource source) async {
    final imageData = await _pickImageData(source);
    if (imageData == null || !mounted) return;

    setState(() {
      _pendingRectangleImageData = imageData;
    });
  }

  Future<void> _updateRectangleImage(
    Rectangle rect, {
    String? imageData,
    bool clearImageData = false,
  }) async {
    final updatedRect = rect.copyWith(
      imageData: imageData,
      clearImageData: clearImageData,
      updatedAt: DateTime.now(),
      isDirty: true,
    );
    await context.read<ClientProvider>().updateRectangle(updatedRect);

    if (mounted) {
      await _loadItem();
    }
  }

  Future<void> _manageRectangleImage(Rectangle rect) async {
    await _showImageSourceOptions(
      onSelectSource: (source) async {
        final imageData = await _pickImageData(source);
        if (imageData == null) return;
        await _updateRectangleImage(rect, imageData: imageData);
      },
      onRemove: _rectangleImageService.hasImage(rect.imageData)
          ? () => _updateRectangleImage(rect, clearImageData: true)
          : null,
    );
  }

  Future<String?> _pickImageData(ImageSource source) async {
    setState(() => _isProcessingImage = true);

    try {
      return await _rectangleImageService.pickImageData(source: source);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error selecting image: $error')),
        );
      }
      return null;
    } finally {
      if (mounted) {
        setState(() => _isProcessingImage = false);
      }
    }
  }

  Future<void> _showImagePreview(String imageData) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: InteractiveViewer(
            child: Image(
              image: _rectangleImageService.buildImageProvider(imageData),
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'This image could not be loaded.',
                    textAlign: TextAlign.center,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRectangleThumbnail(Rectangle rect, int index) {
    final hasImage = _rectangleImageService.hasImage(rect.imageData);
    final image = rect.imageData;

    if (!hasImage || image == null) {
      return CircleAvatar(child: Text('${index + 1}'));
    }

    return InkWell(
      onTap: () => _showImagePreview(image),
      borderRadius: BorderRadius.circular(12),
      child: Ink(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image(
            image: _rectangleImageService.buildImageProvider(image),
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return const Center(child: Icon(Icons.broken_image_outlined));
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPendingImagePreview() {
    final imageData = _pendingRectangleImageData;
    if (!_rectangleImageService.hasImage(imageData) || imageData == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          InkWell(
            onTap: () => _showImagePreview(imageData),
            borderRadius: BorderRadius.circular(12),
            child: Ink(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image(
                  image: _rectangleImageService.buildImageProvider(imageData),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Image selected for the next rectangle.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
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
    final activeDefaultPrices =
        settingsProvider.defaultPrices.where((p) => p.enabled).toList();
    final totalAreaText = 'Total Area: ${_item!.area.toStringAsFixed(2)} sqft';
    final totalCostText =
        'Total Cost: ₹${_item!.totalPrice.toStringAsFixed(2)}';

    return Scaffold(
      appBar: AppBar(title: Text(_item!.name)),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select Price (₹ per sqft):',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      children: [
                        ...activeDefaultPrices.map(
                          (dp) => ChoiceChip(
                            label: Text('₹${dp.price.toStringAsFixed(0)}'),
                            selected:
                                _selectedPrice == dp.price && !_isCustomPrice,
                            onSelected: (selected) {
                              if (!selected) return;

                              setState(() {
                                _selectedPrice = dp.price;
                                _isCustomPrice = false;
                              });
                              _updatePrice(dp.price);
                            },
                          ),
                        ),
                        ChoiceChip(
                          label: const Text('Custom'),
                          selected: _isCustomPrice,
                          onSelected: (selected) {
                            if (!selected) return;

                            setState(() {
                              _selectedPrice = null;
                              _isCustomPrice = true;
                            });
                          },
                        ),
                      ],
                    ),
                    if (_isCustomPrice)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Row(
                          children: [
                            const Text(
                              'Custom Price: ₹',
                              style: TextStyle(fontSize: 16),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 100,
                              child: TextField(
                                controller: _priceController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                decoration:
                                    const InputDecoration(isDense: true),
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
                    final hasImage =
                        _rectangleImageService.hasImage(rect.imageData);

                    return ListTile(
                      leading: _buildRectangleThumbnail(rect, index),
                      title: Text('${rect.length} x ${rect.width}'),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Area: ${(rect.length * rect.width).toStringAsFixed(2)} sqft',
                          ),
                          Text(hasImage ? 'Image attached' : 'No image'),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: hasImage
                                ? 'Change Rectangle Image'
                                : 'Add Rectangle Image',
                            icon: Icon(
                              hasImage
                                  ? Icons.image_outlined
                                  : Icons.add_a_photo_outlined,
                            ),
                            onPressed: _isProcessingImage
                                ? null
                                : () => _manageRectangleImage(rect),
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _showEditRectangleDialog(rect),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              await context
                                  .read<ClientProvider>()
                                  .deleteRectangle(rect.localId!);
                              if (mounted) {
                                await _loadItem();
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                maintainBottomViewPadding: true,
                minimum:
                    const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      totalAreaText,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      totalCostText,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newLengthController,
                            focusNode: _newLengthFocus,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
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
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
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
                    _buildPendingImagePreview(),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _isProcessingImage
                              ? null
                              : () => _showImageSourceOptions(
                                    onSelectSource: _setPendingRectangleImage,
                                    onRemove: _rectangleImageService.hasImage(
                                            _pendingRectangleImageData)
                                        ? () async {
                                            if (!mounted) return;
                                            setState(() {
                                              _pendingRectangleImageData = null;
                                            });
                                          }
                                        : null,
                                  ),
                          icon: const Icon(Icons.add_photo_alternate_outlined),
                          label: Text(
                            _rectangleImageService
                                    .hasImage(_pendingRectangleImageData)
                                ? 'Change Next Image'
                                : 'Attach Image',
                          ),
                        ),
                        if (_rectangleImageService
                            .hasImage(_pendingRectangleImageData))
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _pendingRectangleImageData = null;
                              });
                            },
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove Image'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_isProcessingImage)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
