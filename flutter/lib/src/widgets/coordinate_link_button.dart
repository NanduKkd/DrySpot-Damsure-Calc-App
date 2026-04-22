import 'package:flutter/material.dart';

class CoordinateLinkButton extends StatelessWidget {
  final double latitude;
  final double longitude;
  final VoidCallback onPressed;

  const CoordinateLinkButton({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: const Icon(Icons.location_pin),
        label: Text(
          '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}',
        ),
      ),
    );
  }
}
