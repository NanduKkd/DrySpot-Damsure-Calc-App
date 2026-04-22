import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/client.dart';
import '../../models/warranty.dart';
import '../../providers/client_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/pdf_service.dart';
import '../../utils/warranty_date_utils.dart';

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
  late TextEditingController _areaOfApplicationController;
  late TextEditingController _cardNumberController;
  late TextEditingController _startDateController;
  late TextEditingController _expiryDateController;
  late DateTime _startDate;
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
    _areaOfApplicationController = TextEditingController(text: 'Roof');
    _cardNumberController = TextEditingController();
    _startDate = warrantyDateOnly(DateTime.now());
    _startDateController = TextEditingController();
    _expiryDateController = TextEditingController();
    _syncDateControllers();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _siteAddressController.dispose();
    _phoneController.dispose();
    _areaOfApplicationController.dispose();
    _cardNumberController.dispose();
    _startDateController.dispose();
    _expiryDateController.dispose();
    super.dispose();
  }

  void _syncDateControllers() {
    _startDateController.text = formatWarrantyDate(_startDate);
    _expiryDateController.text = formatWarrantyDate(
      addWarrantyYears(_startDate, _durationYears),
    );
  }

  Future<void> _pickStartDate() async {
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (selectedDate == null) return;

    setState(() {
      _startDate = warrantyDateOnly(selectedDate);
      _syncDateControllers();
    });
  }

  Future<void> _generateWarranty() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = context.read<AuthProvider>();
    final activeFranchiseeId = auth.franchiseeId;
    if (widget.client.franchiseeId != null &&
        activeFranchiseeId != null &&
        widget.client.franchiseeId != activeFranchiseeId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This client belongs to a different session. Please refresh your client list.',
          ),
        ),
      );
      return;
    }

    if (widget.client.remoteId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Client is missing a server ID. Please sync clients and try again.',
          ),
        ),
      );
      return;
    }

    setState(() => _isGenerating = true);

    try {
      final pdfService = PdfService();
      final apiService = context.read<ApiService>();
      final clientProvider = context.read<ClientProvider>();

      final franchiseeName = auth.franchiseeName ??
          'Authorized Franchisee of Damsure Expert Buildcare';
      final startDate = _startDate;

      final file = await pdfService.generateWarrantyPdf(
        client: widget.client,
        customerName: _nameController.text,
        customerAddress: _addressController.text,
        siteAddress: _siteAddressController.text,
        mobileNumber: _phoneController.text,
        areaOfApplication: _areaOfApplicationController.text,
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
                    decoration:
                        const InputDecoration(labelText: 'Site Address'),
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
                    key: const ValueKey('warrantyAreaOfApplicationField'),
                    controller: _areaOfApplicationController,
                    decoration: const InputDecoration(
                      labelText: 'Area of Application',
                    ),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    key: const ValueKey('warrantyCardNumberField'),
                    controller: _cardNumberController,
                    decoration: const InputDecoration(
                      labelText: 'Warranty Card Number',
                    ),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    key: const ValueKey('warrantyStartDateField'),
                    controller: _startDateController,
                    readOnly: true,
                    onTap: _isGenerating ? null : _pickStartDate,
                    decoration: const InputDecoration(
                      labelText: 'Warranty Start Date',
                      suffixIcon: Icon(Icons.calendar_today),
                    ),
                    validator: (value) =>
                        value == null || value.isEmpty ? 'Required' : null,
                  ),
                  TextFormField(
                    key: const ValueKey('warrantyExpiryDateField'),
                    controller: _expiryDateController,
                    readOnly: true,
                    enableInteractiveSelection: false,
                    decoration: const InputDecoration(
                      labelText: 'Warranty Expiry Date',
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<int>(
                    value: _durationYears,
                    decoration: const InputDecoration(
                        labelText: 'Warranty Duration (Years)'),
                    items: [5, 10, 15, 20, 25]
                        .map((y) =>
                            DropdownMenuItem(value: y, child: Text('$y Years')))
                        .toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      setState(() {
                        _durationYears = val;
                        _syncDateControllers();
                      });
                    },
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
