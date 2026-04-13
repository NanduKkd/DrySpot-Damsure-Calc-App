import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/client.dart';
import '../../models/warranty.dart';
import '../../providers/client_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/pdf_service.dart';

class WarrantyFormScreen extends StatefulWidget {
  final Client client;

  const WarrantyFormScreen({super.key, required this.client});

  @override
  State<WarrantyFormScreen> createState() => _WarrantyFormScreenState();
}

class _WarrantyFormScreenState extends State<WarrantyFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _addressController;
  late TextEditingController _siteAddressController;
  late TextEditingController _phoneController;
  late TextEditingController _cardNumberController;
  int _durationYears = 5;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.client.name);
    _addressController = TextEditingController(text: widget.client.address);
    _siteAddressController =
        TextEditingController(text: widget.client.siteAddress);
    _phoneController = TextEditingController(text: widget.client.phone);

    final auth = context.read<AuthProvider>();
    final franchiseeId = auth.franchiseeId ?? 'FRANCH';
    final generatedNumber =
        '$franchiseeId-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';
    _cardNumberController = TextEditingController(text: generatedNumber);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _siteAddressController.dispose();
    _phoneController.dispose();
    _cardNumberController.dispose();
    super.dispose();
  }

  Future<void> _generateWarranty() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isGenerating = true);

    try {
      final auth = context.read<AuthProvider>();
      final pdfService = PdfService();
      final apiService = context.read<ApiService>();
      final clientProvider = context.read<ClientProvider>();

      final franchiseeName = auth.franchiseeName ??
          'Authorized Franchisee of Damsure Expert Buildcare';
      final startDate = DateTime.now();

      final file = await pdfService.generateWarrantyPdf(
        client: widget.client,
        customerName: _nameController.text,
        customerAddress: _addressController.text,
        siteAddress: _siteAddressController.text,
        mobileNumber: _phoneController.text,
        startDate: startDate,
        durationYears: _durationYears,
        franchiseeName: franchiseeName,
        warrantyCardNumber: _cardNumberController.text,
      );

      // Upload to API
      final response = await apiService.uploadWarranty(file.path, {
        'client_id': widget.client.remoteId,
        'start_date': startDate.toIso8601String(),
        'duration_years': _durationYears.toString(),
        'warranty_card_number': _cardNumberController.text,
      });

      // Save to local DB
      final warranty = Warranty(
        clientId: widget.client.localId!,
        remoteId: response['id'],
        warrantyCardNumber: _cardNumberController.text,
        startDate: startDate,
        durationYears: _durationYears,
        pdfUrl: response['pdfUrl'],
        isDirty: false,
        updatedAt: DateTime.parse(response['updatedAt']),
      );

      await clientProvider.addWarranty(warranty);

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error generating warranty: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Warranty Details'),
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration:
                        const InputDecoration(labelText: 'Customer Name'),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _addressController,
                    decoration:
                        const InputDecoration(labelText: 'Customer Address'),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _siteAddressController,
                    decoration: const InputDecoration(labelText: 'Site Address'),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _phoneController,
                    decoration:
                        const InputDecoration(labelText: 'Mobile Number'),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    controller: _cardNumberController,
                    decoration:
                        const InputDecoration(labelText: 'Warranty Card Number'),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    value: _durationYears,
                    decoration: const InputDecoration(
                        labelText: 'Warranty Duration (Years)'),
                    items: [1, 2, 3, 5, 10]
                        .map((y) => DropdownMenuItem(
                            value: y, child: Text('$y Years')))
                        .toList(),
                    onChanged: (val) => setState(() => _durationYears = val!),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: _isGenerating ? null : _generateWarranty,
                    child: const Text('Generate & Upload Warranty'),
                  ),
                ],
              ),
            ),
          ),
          if (_isGenerating)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
