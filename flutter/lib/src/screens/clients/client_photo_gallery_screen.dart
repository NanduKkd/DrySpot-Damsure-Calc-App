import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/client.dart';
import '../../providers/client_provider.dart';
import '../../services/client_photo_service.dart';
import 'client_photo_preview_screen.dart';

class ClientPhotoGalleryScreen extends StatefulWidget {
  ClientPhotoGalleryScreen({
    super.key,
    required this.client,
    ClientPhotoService? photoService,
  }) : photoService = photoService ?? ClientPhotoService();

  final Client client;
  final ClientPhotoService photoService;

  @override
  State<ClientPhotoGalleryScreen> createState() =>
      _ClientPhotoGalleryScreenState();
}

class _ClientPhotoGalleryScreenState extends State<ClientPhotoGalleryScreen> {
  bool _isProcessing = false;

  Client get _currentClient {
    final provider = context.read<ClientProvider>();
    return provider.clients.firstWhere(
      (client) => client.localId == widget.client.localId,
      orElse: () => widget.client,
    );
  }

  Future<void> _showAddPhotoOptions() async {
    if (_isProcessing) return;

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
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addPhoto(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Upload From Gallery'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _addPhoto(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _addPhoto(ImageSource source) async {
    final client = _currentClient;
    final clientLocalId = client.localId;
    if (clientLocalId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the client before adding photos.')),
      );
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final savedPath = await widget.photoService.addPhoto(
        clientLocalId: clientLocalId,
        source: source,
      );

      if (savedPath == null) {
        return;
      }

      if (!mounted) return;

      final provider = context.read<ClientProvider>();
      if (client.photos.contains(savedPath)) {
        return;
      }

      await provider.updateClient(
        client.copyWith(
          photos: [...client.photos, savedPath],
          isDirty: true,
          updatedAt: DateTime.now(),
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo added to this client.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error adding photo: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<bool> _deletePhoto(String photoPath) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Photo'),
        content: const Text('Remove this photo from the client gallery?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) {
      return false;
    }

    setState(() => _isProcessing = true);

    try {
      final client = _currentClient;
      if (!mounted) return false;

      await context.read<ClientProvider>().updateClient(
            client.copyWith(
              photos:
                  client.photos.where((photo) => photo != photoPath).toList(),
              isDirty: true,
              updatedAt: DateTime.now(),
            ),
          );
      await widget.photoService.deletePhoto(photoPath);

      if (!mounted) return true;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo deleted.')),
      );
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting photo: $e')),
      );
      return false;
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  Future<void> _openPhoto(String photoPath) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ClientPhotoPreviewScreen(
          photoPath: photoPath,
          photoService: widget.photoService,
          onDelete: () => _deletePhoto(photoPath),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ClientProvider>(
      builder: (context, provider, _) {
        final client = provider.clients.firstWhere(
          (entry) => entry.localId == widget.client.localId,
          orElse: () => widget.client,
        );
        final photos = client.photos;

        return Scaffold(
          appBar: AppBar(
            title: Text('${client.name} Photos'),
            actions: [
              IconButton(
                tooltip: 'Add Photo',
                onPressed: _isProcessing ? null : _showAddPhotoOptions,
                icon: const Icon(Icons.add_a_photo),
              ),
            ],
          ),
          body: Stack(
            children: [
              if (photos.isEmpty)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.photo_library_outlined, size: 56),
                        const SizedBox(height: 16),
                        const Text('No photos added for this client yet.'),
                        const SizedBox(height: 20),
                        ElevatedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _addPhoto(ImageSource.camera),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Take Photo'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _isProcessing
                              ? null
                              : () => _addPhoto(ImageSource.gallery),
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Upload Photo'),
                        ),
                      ],
                    ),
                  ),
                )
              else
                GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.95,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (context, index) {
                    final photoPath = photos[index];
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey('clientPhotoTile_$index'),
                        onTap:
                            _isProcessing ? null : () => _openPhoto(photoPath),
                        borderRadius: BorderRadius.circular(16),
                        child: Ink(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(16),
                                  child: Image(
                                    image: widget.photoService
                                        .buildImageProvider(photoPath),
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return const Center(
                                        child: Padding(
                                          padding: EdgeInsets.all(16),
                                          child: Text(
                                            'Photo unavailable',
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Material(
                                  color: Colors.black54,
                                  shape: const CircleBorder(),
                                  child: IconButton(
                                    key: ValueKey('clientPhotoDelete_$index'),
                                    tooltip: 'Delete Photo',
                                    icon: const Icon(Icons.delete,
                                        color: Colors.white),
                                    onPressed: _isProcessing
                                        ? null
                                        : () => _deletePhoto(photoPath),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              if (_isProcessing)
                const Center(child: CircularProgressIndicator()),
            ],
          ),
          floatingActionButton: photos.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: _isProcessing ? null : _showAddPhotoOptions,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Photo'),
                ),
        );
      },
    );
  }
}
