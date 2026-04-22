import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:image_picker/image_picker.dart';

class RectangleImageService {
  RectangleImageService({ImagePicker? imagePicker})
      : _imagePicker = imagePicker ?? ImagePicker();

  final ImagePicker _imagePicker;

  Future<String?> pickImageData({required ImageSource source}) async {
    final pickedFile = await _imagePicker.pickImage(
      source: source,
      imageQuality: 75,
      maxWidth: 1600,
      maxHeight: 1600,
    );

    if (pickedFile == null) {
      return null;
    }

    final bytes = await pickedFile.readAsBytes();
    final mimeType = _mimeTypeForPath(pickedFile.path);
    return 'data:$mimeType;base64,${base64Encode(bytes)}';
  }

  bool hasImage(String? imageData) {
    return imageData != null && imageData.trim().isNotEmpty;
  }

  bool isDataUri(String imageData) {
    return imageData.startsWith('data:image/');
  }

  bool isRemoteImage(String imageData) {
    final uri = Uri.tryParse(imageData);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  ImageProvider<Object> buildImageProvider(String imageData) {
    if (isDataUri(imageData)) {
      return MemoryImage(_decodeDataUri(imageData));
    }

    if (isRemoteImage(imageData)) {
      return NetworkImage(imageData);
    }

    return FileImage(File(imageData));
  }

  Uint8List _decodeDataUri(String imageData) {
    final commaIndex = imageData.indexOf(',');
    final encodedData =
        commaIndex >= 0 ? imageData.substring(commaIndex + 1) : imageData;
    return base64Decode(encodedData);
  }

  String _mimeTypeForPath(String path) {
    final lowerPath = path.toLowerCase();

    if (lowerPath.endsWith('.png')) {
      return 'image/png';
    }
    if (lowerPath.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lowerPath.endsWith('.gif')) {
      return 'image/gif';
    }

    return 'image/jpeg';
  }
}
