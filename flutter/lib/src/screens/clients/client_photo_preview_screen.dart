import 'package:flutter/material.dart';

import '../../services/client_photo_service.dart';

class ClientPhotoPreviewScreen extends StatelessWidget {
  const ClientPhotoPreviewScreen({
    super.key,
    required this.photoPath,
    required this.photoService,
    this.onDelete,
  });

  final String photoPath;
  final ClientPhotoService photoService;
  final Future<bool> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete Photo',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final deleted = await onDelete!.call();
                if (deleted && context.mounted) {
                  Navigator.pop(context);
                }
              },
            ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.8,
        maxScale: 4,
        child: Center(
          child: Image(
            image: photoService.buildImageProvider(photoPath),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'This photo could not be loaded.',
                  style: TextStyle(color: Colors.white),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
