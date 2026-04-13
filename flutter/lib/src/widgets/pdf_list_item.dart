import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../services/pdf_service.dart';

class PdfListItem extends StatelessWidget {
  final String title;
  final String subtitle;
  final String pdfUrl;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  const PdfListItem({
    super.key,
    required this.title,
    required this.subtitle,
    required this.pdfUrl,
    required this.onDelete,
    required this.onShare,
  });

  Future<void> _viewPdf(BuildContext context) async {
    try {
      final file = await PdfService().cachePdfFile(
        pdfUrl: pdfUrl,
        fallbackFileName: '$title.pdf',
      );

      final result = await OpenFilex.open(
        file.path,
        type: 'application/pdf',
      );

      if (!context.mounted) return;

      if (result.type != ResultType.done) {
        final message = result.message.isNotEmpty
            ? result.message
            : 'No app available to open PDF.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening PDF: $e')),
      );
    }
  }

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
        onTap: () => _viewPdf(context),
      ),
    );
  }
}
