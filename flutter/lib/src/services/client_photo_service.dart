import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class ClientPhotoService {
  ClientPhotoService({
    ImagePicker? imagePicker,
    Future<Directory> Function()? directoryProvider,
  })  : _imagePicker = imagePicker ?? ImagePicker(),
        _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory;

  final ImagePicker _imagePicker;
  final Future<Directory> Function() _directoryProvider;

  Future<String?> addPhoto({
    required int clientLocalId,
    required ImageSource source,
  }) async {
    final pickedFile = await _imagePicker.pickImage(
      source: source,
      imageQuality: 85,
    );

    if (pickedFile == null) {
      return null;
    }

    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: pickedFile.path,
    );
  }

  Future<String> persistExistingPhoto({
    required int clientLocalId,
    required String sourcePath,
  }) {
    return _persistPhoto(
      clientLocalId: clientLocalId,
      sourcePath: sourcePath,
    );
  }

  Future<void> deletePhoto(String photoPath) async {
    if (isRemotePhotoPath(photoPath)) {
      return;
    }

    final localPath = _normalizeLocalPath(photoPath);
    final file = File(localPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  bool isRemotePhotoPath(String photoPath) {
    final uri = Uri.tryParse(photoPath);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  ImageProvider<Object> buildImageProvider(String photoPath) {
    if (isRemotePhotoPath(photoPath)) {
      return NetworkImage(photoPath);
    }

    return FileImage(File(_normalizeLocalPath(photoPath)));
  }

  String _normalizeLocalPath(String photoPath) {
    final uri = Uri.tryParse(photoPath);
    if (uri != null && uri.scheme == 'file') {
      return uri.toFilePath();
    }

    return photoPath;
  }

  Future<String> _persistPhoto({
    required int clientLocalId,
    required String sourcePath,
  }) async {
    final documentsDir = await _directoryProvider();
    final clientDir = Directory(
      path.join(documentsDir.path, 'client_photos', 'client_$clientLocalId'),
    );

    if (!await clientDir.exists()) {
      await clientDir.create(recursive: true);
    }

    final extension = path.extension(sourcePath).trim().isNotEmpty
        ? path.extension(sourcePath)
        : '.jpg';
    final fileName = 'photo_${DateTime.now().microsecondsSinceEpoch}$extension';
    final destinationPath = path.join(clientDir.path, fileName);

    final sourceFile = File(sourcePath);
    final copiedFile = await sourceFile.copy(destinationPath);
    return copiedFile.path;
  }
}
