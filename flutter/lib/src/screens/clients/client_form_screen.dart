import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/client.dart';
import '../../services/geo_service.dart';
import '../../services/map_launcher_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/client_provider.dart';
import '../../widgets/coordinate_link_button.dart';

class ClientFormScreen extends StatefulWidget {
  final Client? client;
  final GeoService? geoService;
  final MapLauncherService? mapLauncherService;

  const ClientFormScreen({
    super.key,
    this.client,
    this.geoService,
    this.mapLauncherService,
  });

  @override
  State<ClientFormScreen> createState() => _ClientFormScreenState();
}

class _ClientFormScreenState extends State<ClientFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final GeoService _geoService;
  late final MapLauncherService _mapLauncherService;
  late String _name;
  String? _address;
  String? _siteAddress;
  String? _email;
  String? _phone;
  double? _latitude;
  double? _longitude;
  bool _isCapturingLocation = false;
  String _locationStatus = 'Location not captured.';

  @override
  void initState() {
    super.initState();
    _geoService = widget.geoService ?? GeoService();
    _mapLauncherService = widget.mapLauncherService ?? MapLauncherService();
    _name = widget.client?.name ?? '';
    _address = widget.client?.address;
    _siteAddress = widget.client?.siteAddress;
    _email = widget.client?.email;
    _phone = widget.client?.phone;
    _latitude = widget.client?.latitude;
    _longitude = widget.client?.longitude;
    _locationStatus = (_latitude != null && _longitude != null)
        ? 'Location captured.'
        : 'Location not captured.';

    if (widget.client == null) {
      _captureLocation();
    }
  }

  Future<void> _captureLocation() async {
    if (_isCapturingLocation) return;
    if (mounted) {
      setState(() {
        _isCapturingLocation = true;
        _locationStatus = 'Capturing location...';
      });
    }

    try {
      final location = await _geoService.getCurrentLocation();
      if (!mounted) return;

      setState(() {
        _isCapturingLocation = false;
        if (location != null) {
          _latitude = location.latitude;
          _longitude = location.longitude;
          _locationStatus = 'Location captured.';
        } else {
          _locationStatus =
              'Location unavailable. Enable GPS/permission and retry.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isCapturingLocation = false;
        _locationStatus = 'Unable to capture location right now. Retry.';
      });
    }
  }

  Future<void> _openLocationInMap() async {
    if (_latitude == null || _longitude == null) return;

    final didOpen = await _mapLauncherService.openCoordinates(
      latitude: _latitude!,
      longitude: _longitude!,
    );

    if (!mounted || didOpen) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('Could not open a map app for this location.')),
    );
  }

  Future<void> _confirmAndCaptureCurrentLocation() async {
    if (_isCapturingLocation) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change Location'),
        content: const Text(
          'Use your device\'s current location for this client?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Change'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _captureLocation();
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
        siteAddress: _siteAddress,
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
      appBar: AppBar(
          title: Text(widget.client == null ? 'New Client' : 'Edit Client')),
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
                initialValue: _siteAddress,
                decoration: const InputDecoration(labelText: 'Site Address'),
                onSaved: (v) => _siteAddress = v,
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
              if (_latitude != null && _longitude != null)
                CoordinateLinkButton(
                  latitude: _latitude!,
                  longitude: _longitude!,
                  onPressed: _openLocationInMap,
                )
              else
                Text(_locationStatus),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _isCapturingLocation
                    ? null
                    : _confirmAndCaptureCurrentLocation,
                child: Text(
                  _isCapturingLocation
                      ? 'Updating location...'
                      : 'Change to Current Location',
                ),
              ),
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
