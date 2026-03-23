import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/item.dart';
import '../models/rectangle.dart';
import '../providers/client_provider.dart';

class RectangleEditor extends StatelessWidget {
  final Item item;
  final VoidCallback onChanged;

  const RectangleEditor({
    super.key,
    required this.item,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ...item.rectangles.where((r) => r.deletedAt == null).map((rectangle) => ListTile(
              title: Text('${rectangle.length} ft x ${rectangle.width} ft'),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () async {
                  await context.read<ClientProvider>().deleteRectangle(rectangle.localId!);
                  onChanged();
                },
              ),
            )),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: ElevatedButton(
            onPressed: () => _addRectangle(context),
            child: const Text('Add Rectangle'),
          ),
        ),
      ],
    );
  }

  Future<void> _addRectangle(BuildContext context) async {
    final lengthController = TextEditingController();
    final widthController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Rectangle'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: lengthController, decoration: const InputDecoration(labelText: 'Length (ft)'), keyboardType: TextInputType.number),
            TextField(controller: widthController, decoration: const InputDecoration(labelText: 'Width (ft)'), keyboardType: TextInputType.number),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final length = double.tryParse(lengthController.text) ?? 0;
              final width = double.tryParse(widthController.text) ?? 0;
              if (length > 0 && width > 0) {
                final rect = Rectangle(
                  itemId: item.localId,
                  length: length,
                  width: width,
                );
                await context.read<ClientProvider>().addRectangle(rect);
                if (context.mounted) Navigator.pop(context);
                onChanged();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}
