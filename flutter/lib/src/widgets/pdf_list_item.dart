import 'package:flutter/material.dart';

class PdfListItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final String pdfUrl;
  final VoidCallback? onDelete;
  final VoidCallback onShare;
  final VoidCallback onView;

  const PdfListItem({
    super.key,
    required this.title,
    required this.subtitle,
    required this.pdfUrl,
    required this.onDelete,
    required this.onShare,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.picture_as_pdf, color: Colors.red, size: 32),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.share),
              onPressed: onShare,
              tooltip: 'Share',
            ),
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: onDelete,
              tooltip: 'Delete',
            ),
          ],
        ),
        onTap: onView,
      ),
    );
  }
}
