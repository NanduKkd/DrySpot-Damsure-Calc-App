import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../services/pdf_service.dart';
import '../../services/api_service.dart';
import '../../providers/auth_provider.dart';
import '../../services/session_manager.dart';

class PdfPreviewScreen extends StatefulWidget {
  const PdfPreviewScreen({
    super.key,
    required this.title,
    required this.pdfUrl,
  });

  final String title;
  final String pdfUrl;

  @override
  State<PdfPreviewScreen> createState() => _PdfPreviewScreenState();
}

class _PdfPreviewScreenState extends State<PdfPreviewScreen> {
  late final PdfService _pdfService;
  late final Future<Uint8List> _pdfBytesFuture;

  @override
  void initState() {
    super.initState();
    _pdfService = PdfService(apiService: context.read<ApiService>());
    final auth = context.read<AuthProvider>();
    final session = auth.sessionSnapshot;
    _pdfBytesFuture = session == null
        ? Future<Uint8List>.error(const StaleSessionException())
        : _pdfService.loadPdfBytes(
            widget.pdfUrl,
            session: session,
            isSessionCurrent: () =>
                auth.sessionSnapshot?.generation == session.generation,
          );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: FutureBuilder<Uint8List>(
        future: _pdfBytesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Error loading PDF: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final bytes = snapshot.data;
          if (bytes == null) {
            return const Center(
              child: Text('PDF could not be loaded.'),
            );
          }

          return PdfPreview(
            build: (format) async => bytes,
            allowPrinting: false,
            allowSharing: false,
            canDebug: false,
            canChangePageFormat: false,
            canChangeOrientation: false,
          );
        },
      ),
    );
  }
}
