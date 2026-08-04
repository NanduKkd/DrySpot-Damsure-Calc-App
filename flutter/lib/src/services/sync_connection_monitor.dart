import 'package:connectivity_plus/connectivity_plus.dart';

/// A small, injectable link-restoration signal for APP-112. It deliberately
/// reports transport availability only; SyncProvider still requires an
/// explicit user retry and never treats a restored link as permission to send.
abstract interface class SyncConnectionMonitor {
  Stream<bool> get connectionChanges;
}

class PlatformSyncConnectionMonitor implements SyncConnectionMonitor {
  PlatformSyncConnectionMonitor({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<bool> get connectionChanges => _connectivity.onConnectivityChanged
      .map((results) =>
          results.any((result) => result != ConnectivityResult.none))
      .distinct();
}
