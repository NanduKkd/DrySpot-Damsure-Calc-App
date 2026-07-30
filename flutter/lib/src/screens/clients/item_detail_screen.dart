import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  static const double _maxMeasurement = 10000;

  final _priceController = TextEditingController();
  final _newLengthController = TextEditingController();
  final _newWidthController = TextEditingController();
  final _newLengthFocus = FocusNode();
  final _newWidthFocus = FocusNode();
  final Map<Object, _RectangleInputControllers> _rectangleInputs = {};
  final Map<Object, _RectangleValidationErrors> _rectangleErrors = {};

  late final RectangleImageService _rectangleImageService;

  Item? _item;
  bool _isLoading = true;
  bool _didAutofocusNewLength = false;
  bool _isProcessingImage = false;
  double? _selectedPrice;
  bool _isCustomPrice = false;
  String? _pendingRectangleImageData;
  String? _newLengthError;
  String? _newWidthError;

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
    for (final input in _rectangleInputs.values) {
      input.dispose();
    }
    super.dispose();
  }

  Object _rectangleKey(Rectangle rect) => rect.localId ?? rect.remoteId;

  String _formatMeasurement(double value) {
    if (value == value.truncateToDouble()) {
      return value.toStringAsFixed(0);
    }
    return value.toString();
  }

  String? _measurementError(String value, String label) {
    if (value.trim().isEmpty) return 'Enter $label';

    final parsed = double.tryParse(value.trim());
    if (parsed == null) return 'Enter a valid number';
    if (!parsed.isFinite) return '$label must be finite';
    if (parsed <= 0) return '$label must be greater than 0';
    if (parsed > _maxMeasurement) {
      return '$label must be 10,000 ft or less';
    }
    return null;
  }

  void _syncRectangleInputs(List<Rectangle> rectangles) {
    final activeKeys = rectangles.map(_rectangleKey).toSet();
    final staleKeys = _rectangleInputs.keys
        .where((key) => !activeKeys.contains(key))
        .toList();

    for (final key in staleKeys) {
      _rectangleInputs.remove(key)?.dispose();
      _rectangleErrors.remove(key);
    }

    for (final rect in rectangles) {
      final key = _rectangleKey(rect);
      final input = _rectangleInputs.putIfAbsent(
        key,
        () => _RectangleInputControllers(
          length: _formatMeasurement(rect.length),
          width: _formatMeasurement(rect.width),
        ),
      );

      if (!input.lengthFocus.hasFocus) {
        input.lengthController.text = _formatMeasurement(rect.length);
      }
      if (!input.widthFocus.hasFocus) {
        input.widthController.text = _formatMeasurement(rect.width);
      }
    }
  }

  void _requestNewLengthFocus({bool showKeyboard = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusScope.of(context).requestFocus(_newLengthFocus);
        if (showKeyboard) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _newLengthFocus.hasFocus) {
              SystemChannels.textInput.invokeMethod<void>('TextInput.show');
            }
          });
          WidgetsBinding.instance.scheduleFrame();
        }
      }
    });
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
        _syncRectangleInputs(item.rectangles);
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

    if (!_didAutofocusNewLength) {
      _didAutofocusNewLength = true;
      _requestNewLengthFocus();
    }
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

    final lengthError =
        _measurementError(_newLengthController.text, 'Length');
    final widthError = _measurementError(_newWidthController.text, 'Width');

    if (lengthError != null || widthError != null) {
      setState(() {
        _newLengthError = lengthError;
        _newWidthError = widthError;
      });
      return;
    }

    final length = double.parse(_newLengthController.text.trim());
    final width = double.parse(_newWidthController.text.trim());

    final rectangle = Rectangle(
      itemId: _item!.localId!,
      length: length,
      width: width,
      imageData: _pendingRectangleImageData,
    );

    await context.read<ClientProvider>().addRectangle(rectangle);

    if (!mounted) return;
    setState(() {
      _newLengthController.clear();
      _newWidthController.clear();
      _newLengthError = null;
      _newWidthError = null;
      _pendingRectangleImageData = null;
    });
    await _loadItem();
    _requestNewLengthFocus(showKeyboard: true);
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

  void _clearRectangleError(
    Rectangle rect, {
    bool length = false,
    bool width = false,
  }) {
    final key = _rectangleKey(rect);
    final errors = _rectangleErrors[key];
    if (errors == null) return;

    setState(() {
      _rectangleErrors[key] = _RectangleValidationErrors(
        length: length ? null : errors.length,
        width: width ? null : errors.width,
      );
    });
  }

  Future<bool> _saveRectangleFromInputs(Rectangle rect) async {
    final input = _rectangleInputs[_rectangleKey(rect)];
    if (input == null) return false;

    final lengthError =
        _measurementError(input.lengthController.text, 'Length');
    final widthError = _measurementError(input.widthController.text, 'Width');

    if (lengthError != null || widthError != null) {
      setState(() {
        _rectangleErrors[_rectangleKey(rect)] = _RectangleValidationErrors(
          length: lengthError,
          width: widthError,
        );
      });
      return false;
    }

    final length = double.parse(input.lengthController.text.trim());
    final width = double.parse(input.widthController.text.trim());

    if (length == rect.length && width == rect.width) {
      setState(() {
        _rectangleErrors.remove(_rectangleKey(rect));
      });
      return true;
    }

    final updatedRect = rect.copyWith(
      length: length,
      width: width,
      updatedAt: DateTime.now(),
      isDirty: true,
    );
    await context.read<ClientProvider>().updateRectangle(updatedRect);

    if (mounted) {
      await _loadItem();
    }
    return true;
  }

  void _focusNextAfterRectangle(int index) {
    final rectangles = _item?.rectangles ?? [];
    if (index + 1 < rectangles.length) {
      _rectangleInputs[_rectangleKey(rectangles[index + 1])]
          ?.lengthFocus
          .requestFocus();
      return;
    }

    _requestNewLengthFocus(showKeyboard: true);
  }

  Widget _buildMeasurementRow(Rectangle rect, int index) {
    final input = _rectangleInputs[_rectangleKey(rect)]!;
    final errors = _rectangleErrors[_rectangleKey(rect)];
    final hasImage = _rectangleImageService.hasImage(rect.imageData);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: input.lengthController,
                  focusNode: input.lengthFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Length (ft)',
                    border: const OutlineInputBorder(),
                    errorText: errors?.length,
                  ),
                  onChanged: (_) => _clearRectangleError(rect, length: true),
                  textInputAction: TextInputAction.next,
                  onEditingComplete: () {},
                  onSubmitted: (_) => input.widthFocus.requestFocus(),
                  onTapOutside: (_) => _saveRectangleFromInputs(rect),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: input.widthController,
                  focusNode: input.widthFocus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Width (ft)',
                    border: const OutlineInputBorder(),
                    errorText: errors?.width,
                  ),
                  onChanged: (_) => _clearRectangleError(rect, width: true),
                  textInputAction: TextInputAction.next,
                  onEditingComplete: () {},
                  onSubmitted: (_) async {
                    final saved = await _saveRectangleFromInputs(rect);
                    if (saved && mounted) {
                      _focusNextAfterRectangle(index);
                    }
                  },
                  onTapOutside: (_) => _saveRectangleFromInputs(rect),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip:
                    hasImage ? 'Change Rectangle Image' : 'Add Rectangle Image',
                icon: Icon(
                  hasImage ? Icons.image_outlined : Icons.add_a_photo_outlined,
                ),
                onPressed: _isProcessingImage
                    ? null
                    : () => _manageRectangleImage(rect),
              ),
              IconButton(
                tooltip: 'Delete Measurement',
                icon: const Icon(Icons.delete_outline),
                color: Colors.red,
                onPressed: rect.localId == null
                    ? null
                    : () async {
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
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${rect.area.toStringAsFixed(1)} sqft',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (hasImage)
            Text(
              'Image attached',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  Widget _buildNewMeasurementRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _newLengthController,
              focusNode: _newLengthFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Length (ft)',
                border: const OutlineInputBorder(),
                errorText: _newLengthError,
              ),
              onChanged: (_) => setState(() => _newLengthError = null),
              textInputAction: TextInputAction.next,
              onEditingComplete: () {},
              onSubmitted: (_) => _newWidthFocus.requestFocus(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _newWidthController,
              focusNode: _newWidthFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Width (ft)',
                border: const OutlineInputBorder(),
                errorText: _newWidthError,
              ),
              onChanged: (_) => setState(() => _newWidthError = null),
              textInputAction: TextInputAction.next,
              onEditingComplete: () {},
              onSubmitted: (_) => _submitNewRectangle(),
            ),
          ),
          const SizedBox(width: 104),
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
                child: ListView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        'Measurements',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    for (var index = 0;
                        index < _item!.rectangles.length;
                        index++)
                      _buildMeasurementRow(_item!.rectangles[index], index),
                    _buildNewMeasurementRow(),
                  ],
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

class _RectangleInputControllers {
  final TextEditingController lengthController;
  final TextEditingController widthController;
  final FocusNode lengthFocus;
  final FocusNode widthFocus;

  _RectangleInputControllers({
    required String length,
    required String width,
  })  : lengthController = TextEditingController(text: length),
        widthController = TextEditingController(text: width),
        lengthFocus = FocusNode(),
        widthFocus = FocusNode();

  void dispose() {
    lengthController.dispose();
    widthController.dispose();
    lengthFocus.dispose();
    widthFocus.dispose();
  }
}

class _RectangleValidationErrors {
  final String? length;
  final String? width;

  const _RectangleValidationErrors({this.length, this.width});
}
