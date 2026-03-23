import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/client.dart';
import '../../services/geo_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/client_provider.dart';

class ClientFormScreen extends StatefulWidget {
  final Client? client;
  const ClientFormScreen({super.key, this.client});

  @override
  State<ClientFormScreen> createState() => _ClientFormScreenState();
}

class _ClientFormScreenState extends State<ClientFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late String _name;
  String? _address;
  String? _email;
  String? _phone;
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _name = widget.client?.name ?? '';
    _address = widget.client?.address;
    _email = widget.client?.email;
    _phone = widget.client?.phone;
    _latitude = widget.client?.latitude;
    _longitude = widget.client?.longitude;

    if (widget.client == null) {
      _captureLocation();
    }
  }

  Future<void> _captureLocation() async {
    final location = await GeoService().getCurrentLocation();
    if (location != null) {
      setState(() {
        _latitude = location.latitude;
        _longitude = location.longitude;
      });
    }
  }

  Future<void> _save() async {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      final clientProvider = context.read<ClientProvider>();
      final auth = context.read<AuthProvider>();

      final client = Client(
        localId: widget.client?.localId,
        remoteId: widget.client?.remoteId,
        franchiseeId: auth.franchiseeId,
        name: _name,
        address: _address,
        email: _email,
        phone: _phone,
        latitude: _latitude,
        longitude: _longitude,
        photos: widget.client?.photos ?? [],
        updatedAt: DateTime.now(),
      );

      if (widget.client == null) {
        await clientProvider.addClient(client);
      } else {
        await clientProvider.updateClient(client);
      }
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.client == null ? 'New Client' : 'Edit Client')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                initialValue: _name,
                decoration: const InputDecoration(labelText: 'Client Name *'),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                onSaved: (v) => _name = v!,
              ),
              TextFormField(
                initialValue: _address,
                decoration: const InputDecoration(labelText: 'Address'),
                onSaved: (v) => _address = v,
              ),
              TextFormField(
                initialValue: _email,
                decoration: const InputDecoration(labelText: 'Email'),
                onSaved: (v) => _email = v,
              ),
              TextFormField(
                initialValue: _phone,
                decoration: const InputDecoration(labelText: 'Phone Number'),
                onSaved: (v) => _phone = v,
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 20),
              if (_latitude != null)
                Text('Location: $_latitude, $_longitude')
              else
                const Text('Capturing location...'),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
