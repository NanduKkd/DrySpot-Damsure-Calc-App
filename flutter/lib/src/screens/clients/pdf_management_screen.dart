import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../../models/client.dart';
import '../../models/warranty.dart';
import '../../models/proposal.dart';
import '../../providers/client_provider.dart';
import '../../services/api_service.dart';
import '../../services/pdf_service.dart';
import '../../widgets/pdf_list_item.dart';
import 'warranty_form_screen.dart';

class PdfManagementScreen extends StatefulWidget {
  final Client client;

  const PdfManagementScreen({super.key, required this.client});

  @override
  State<PdfManagementScreen> createState() => _PdfManagementScreenState();
}

class _PdfManagementScreenState extends State<PdfManagementScreen> {
  bool _isGenerating = false;
  final PdfService _pdfService = PdfService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    final provider = context.read<ClientProvider>();
    await provider.loadWarranties(widget.client.localId!);
    await provider.loadProposals(widget.client.localId!);
  }

  Future<void> _generateProposal() async {
    setState(() => _isGenerating = true);
    try {
      final apiService = context.read<ApiService>();
      final clientProvider = context.read<ClientProvider>();

      final file = await _pdfService.generateProposalPdf(widget.client);

      // Upload to API
      final response = await apiService.uploadProposal(file.path, {
        'client_id': widget.client.remoteId,
      });

      // Save to local DB
      final proposal = Proposal(
        clientId: widget.client.localId!,
        remoteId: response['id'],
        pdfUrl: response['pdfUrl'],
        isDirty: false,
        updatedAt: DateTime.parse(response['updatedAt']),
      );

      await clientProvider.addProposal(proposal);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Proposal generated and uploaded successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating proposal: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<void> _sharePdf({
    required String pdfUrl,
    required String fallbackFileName,
  }) async {
    try {
      final bytes = await _pdfService.loadPdfBytes(pdfUrl);
      final fileName = _pdfService.buildPdfFileName(
        fallbackName: fallbackFileName,
        sourceUrl: pdfUrl,
      );

      await Printing.sharePdf(
        bytes: bytes,
        filename: fileName,
      );
    } catch (e) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error sharing PDF: $e')),
      );
    }
  }

  Future<void> _createWarranty() async {
    final clientProvider = context.read<ClientProvider>();
    final existingWarranties = clientProvider.currentClientWarranties;

    if (existingWarranties.isNotEmpty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Warranty Exists'),
          content: const Text(
              'A warranty already exists for this client. Creating a new one will delete the existing one. Continue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete & Continue',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );

      if (confirm != true) return;

      // Soft delete existing warranty before proceeding
      for (var w in existingWarranties) {
        await clientProvider.deleteWarranty(w.localId!, widget.client.localId!);
      }
    }

    if (!mounted) return;

    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => WarrantyFormScreen(client: widget.client),
      ),
    );

    if (result == true) {
      _loadData();
    }
  }

  Future<void> _deleteWarranty(Warranty warranty) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Warranty'),
        content: const Text('Are you sure you want to delete this warranty?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await context
          .read<ClientProvider>()
          .deleteWarranty(warranty.localId!, widget.client.localId!);
    }
  }

  Future<void> _deleteProposal(Proposal proposal) async {
    final apiService = context.read<ApiService>();
    final clientProvider = context.read<ClientProvider>();
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Proposal'),
        content: const Text('Are you sure you want to delete this proposal?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      try {
        if (proposal.remoteId.isNotEmpty) {
          await apiService.deleteProposal(proposal.remoteId);
        }
        await clientProvider.deleteProposal(
          proposal.localId!,
          widget.client.localId!,
        );
      } catch (e) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting proposal: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('PDF Management'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Warranty'),
              Tab(text: 'Proposal'),
            ],
          ),
        ),
        body: Stack(
          children: [
            TabBarView(
              children: [
                _buildWarrantyTab(),
                _buildProposalTab(),
              ],
            ),
            if (_isGenerating)
              const Center(
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWarrantyTab() {
    return Consumer<ClientProvider>(
      builder: (context, provider, _) {
        final warranties = provider.currentClientWarranties;
        if (warranties.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('No warranty generated yet.'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _createWarranty,
                  child: const Text('Create Warranty'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: warranties.length,
          itemBuilder: (context, index) {
            final warranty = warranties[index];
            return PdfListItem(
              title: 'Warranty - ${warranty.warrantyCardNumber}',
              subtitle:
                  'Created: ${warranty.updatedAt.toLocal().toString().split('.')[0]}',
              pdfUrl: warranty.pdfUrl,
              onDelete: () => _deleteWarranty(warranty),
              onShare: () {
                _sharePdf(
                  pdfUrl: warranty.pdfUrl,
                  fallbackFileName:
                      'warranty_${warranty.warrantyCardNumber}.pdf',
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildProposalTab() {
    return Consumer<ClientProvider>(
      builder: (context, provider, _) {
        final proposals = provider.currentClientProposals;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(
                onPressed: _isGenerating ? null : _generateProposal,
                icon: const Icon(Icons.add),
                label: const Text('Create Proposal'),
              ),
            ),
            Expanded(
              child: proposals.isEmpty
                  ? const Center(child: Text('No proposals generated yet.'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: proposals.length,
                      itemBuilder: (context, index) {
                        final proposal = proposals[index];
                        return PdfListItem(
                          title: 'Proposal ${proposals.length - index}',
                          subtitle:
                              'Created: ${proposal.updatedAt.toLocal().toString().split('.')[0]}',
                          pdfUrl: proposal.pdfUrl,
                          onDelete: () => _deleteProposal(proposal),
                          onShare: () {
                            _sharePdf(
                              pdfUrl: proposal.pdfUrl,
                              fallbackFileName:
                                  'proposal_${proposal.remoteId}.pdf',
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
