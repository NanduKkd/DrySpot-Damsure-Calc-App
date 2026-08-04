import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../models/client.dart';
import '../../models/warranty.dart';
import '../../models/proposal.dart';
import '../../providers/client_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/pdf_service.dart';
import '../../services/warranty_replacement_intent_store.dart';
import '../../widgets/pdf_list_item.dart';
import 'warranty_form_screen.dart';

class PdfManagementScreen extends StatefulWidget {
  final Client client;
  final WarrantyReplacementIntentStore? replacementIntentStore;

  const PdfManagementScreen({
    super.key,
    required this.client,
    this.replacementIntentStore,
  });

  @override
  State<PdfManagementScreen> createState() => _PdfManagementScreenState();
}

class _PdfManagementScreenState extends State<PdfManagementScreen> {
  bool _isGenerating = false;
  bool _isWarrantyMutationInFlight = false;
  late final PdfService _pdfService;
  late final WarrantyReplacementIntentStore _replacementIntentStore;

  @override
  void initState() {
    super.initState();
    _pdfService = PdfService(apiService: context.read<ApiService>());
    _replacementIntentStore =
        widget.replacementIntentStore ?? WarrantyReplacementIntentStore();
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
      final auth = context.read<AuthProvider>();
      final session = auth.sessionSnapshot;
      if (session == null ||
          widget.client.franchiseeId != session.franchiseeId) {
        return;
      }

      final file = await _pdfService.generateProposalPdf(
        widget.client,
        session: session,
        isSessionCurrent: () => auth.isCurrentSession(session),
      );

      if (!mounted || auth.sessionSnapshot?.generation != session.generation) {
        return;
      }

      // Upload to API
      final response = await apiService.uploadProposalForSession(
        file.path,
        {'client_id': widget.client.remoteId},
        session,
        isSessionCurrent: () =>
            auth.sessionSnapshot?.generation == session.generation,
      );
      if (auth.sessionSnapshot?.generation != session.generation) return;

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
      final auth = context.read<AuthProvider>();
      final session = auth.sessionSnapshot;
      if (session == null ||
          widget.client.franchiseeId != session.franchiseeId) {
        return;
      }
      final bytes = await _pdfService.loadPdfBytes(
        pdfUrl,
        session: session,
        isSessionCurrent: () =>
            auth.sessionSnapshot?.generation == session.generation,
      );
      if (!mounted || auth.sessionSnapshot?.generation != session.generation) {
        return;
      }
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

  Future<void> _viewPdf({
    required String pdfUrl,
    required String fallbackFileName,
  }) async {
    try {
      final auth = context.read<AuthProvider>();
      final session = auth.sessionSnapshot;
      if (session == null ||
          widget.client.franchiseeId != session.franchiseeId) {
        return;
      }
      final file = await _pdfService.cachePdfFile(
        pdfUrl: pdfUrl,
        fallbackFileName: fallbackFileName,
        session: session,
        isSessionCurrent: () =>
            auth.sessionSnapshot?.generation == session.generation,
      );
      if (!mounted || auth.sessionSnapshot?.generation != session.generation) {
        return;
      }
      final result = await OpenFilex.open(file.path, type: 'application/pdf');
      if (!mounted || auth.sessionSnapshot?.generation != session.generation) {
        return;
      }
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.message.isNotEmpty
                  ? result.message
                  : 'No app available to open PDF.',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error opening PDF: $e')),
      );
    }
  }

  Future<void> _createWarranty() async {
    if (!mounted || _isWarrantyMutationInFlight) return;
    setState(() => _isWarrantyMutationInFlight = true);
    try {
      final activeWarranties =
          context.read<ClientProvider>().currentClientWarranties;
      final activeWarranty =
          activeWarranties.isEmpty ? null : activeWarranties.first;
      WarrantyReplacementIntent? replacementIntent;
      if (activeWarranty != null) {
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Permanently replace warranty?'),
            content: Text(
              'Warranty "${activeWarranty.warrantyCardNumber}" '
              '(server version ${activeWarranty.version}) will be permanently deleted. '
              'Its record and stored PDF cannot be recovered. Continue only if you '
              'intend to replace this exact warranty.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Permanently replace'),
              ),
            ],
          ),
        );
        if (replace != true || !mounted) return;
        replacementIntent = await _replacementIntentStore.loadOrCreate(
          activeWarranty.remoteId,
        );
        if (!mounted) return;
      }

      final result = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => WarrantyFormScreen(
            client: widget.client,
            warrantyToReplace: activeWarranty,
            replacementIdempotencyKey: replacementIntent?.idempotencyKey,
            replacementTargetWarrantyId: replacementIntent?.targetWarrantyId,
          ),
        ),
      );

      if (result == true) {
        if (activeWarranty != null) {
          await _replacementIntentStore.clear(activeWarranty.remoteId);
        }
        await _loadData();
      }
    } finally {
      if (mounted) setState(() => _isWarrantyMutationInFlight = false);
    }
  }

  Future<void> _deleteWarranty(Warranty warranty) async {
    if (!mounted || _isWarrantyMutationInFlight) return;
    setState(() => _isWarrantyMutationInFlight = true);
    try {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permanently delete warranty?'),
          content: Text(
            'Warranty "${warranty.warrantyCardNumber}" '
            '(server version ${warranty.version}) and its stored PDF will be '
            'permanently deleted and cannot be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text(
                'Permanently delete',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        ),
      );

      if (confirm == true && mounted) {
        final auth = context.read<AuthProvider>();
        final session = auth.sessionSnapshot;
        if (session == null ||
            widget.client.franchiseeId != session.franchiseeId) {
          return;
        }
        if (warranty.remoteId.isEmpty) {
          throw const ApiException(
            'This warranty has no server ID. Sync and try again.',
          );
        }
        if (auth.sessionSnapshot?.generation != session.generation) return;
        await context.read<ApiService>().deleteWarrantyForSession(
              id: warranty.remoteId,
              warrantyCardNumber: warranty.warrantyCardNumber,
              warrantyVersion: warranty.version,
              irreversibleConfirmation: irreversibleWarrantyConfirmationText(
                warranty.warrantyCardNumber,
              ),
              idempotencyKey: const Uuid().v4(),
              session: session,
              isSessionCurrent: () =>
                  auth.sessionSnapshot?.generation == session.generation,
            );
        if (auth.sessionSnapshot?.generation != session.generation) return;
        if (!mounted) return;
        await context
            .read<ClientProvider>()
            .deleteWarranty(warranty.localId!, widget.client.localId!);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error deleting warranty: $e')),
      );
    } finally {
      if (mounted) setState(() => _isWarrantyMutationInFlight = false);
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
        final auth = context.read<AuthProvider>();
        final session = auth.sessionSnapshot;
        if (session == null ||
            widget.client.franchiseeId != session.franchiseeId) {
          return;
        }
        if (proposal.remoteId.isNotEmpty) {
          if (auth.sessionSnapshot?.generation != session.generation) return;
          await apiService.deleteProposalForSession(
            proposal.remoteId,
            session,
            isSessionCurrent: () =>
                auth.sessionSnapshot?.generation == session.generation,
          );
        }
        if (auth.sessionSnapshot?.generation != session.generation) return;
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
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(
                onPressed: _isGenerating || _isWarrantyMutationInFlight
                    ? null
                    : _createWarranty,
                icon: const Icon(Icons.add),
                label: const Text('Create Warranty'),
              ),
            ),
            Expanded(
              child: warranties.isEmpty
                  ? const Center(child: Text('No warranties generated yet.'))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: warranties.length,
                      itemBuilder: (context, index) {
                        final warranty = warranties[index];
                        return PdfListItem(
                          title: 'Warranty - ${warranty.warrantyCardNumber}',
                          subtitle:
                              'Created: ${warranty.updatedAt.toLocal().toString().split('.')[0]}',
                          pdfUrl: warranty.pdfUrl,
                          onDelete: _isWarrantyMutationInFlight
                              ? null
                              : () => _deleteWarranty(warranty),
                          onShare: () {
                            _sharePdf(
                              pdfUrl: warranty.pdfUrl,
                              fallbackFileName:
                                  'warranty_${warranty.warrantyCardNumber}.pdf',
                            );
                          },
                          onView: () => _viewPdf(
                            pdfUrl: warranty.pdfUrl,
                            fallbackFileName:
                                'warranty_${warranty.warrantyCardNumber}.pdf',
                          ),
                        );
                      },
                    ),
            ),
          ],
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
                          onView: () => _viewPdf(
                            pdfUrl: proposal.pdfUrl,
                            fallbackFileName:
                                'proposal_${proposal.remoteId}.pdf',
                          ),
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
