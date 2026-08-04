import 'package:flutter/widgets.dart';

/// An immutable capability for exactly one authenticated app session.
///
/// Callers must capture this value before starting asynchronous work and ask
/// [SessionManager] whether it is still current before issuing a request or
/// applying a result.  The generation is deliberately memory-only: logging
/// out makes every outstanding capability unusable immediately.
class SessionSnapshot {
  const SessionSnapshot({
    required this.token,
    required this.userName,
    required this.franchiseeId,
    required this.franchiseeName,
    required this.generation,
  });

  final String token;
  final String? userName;
  final String franchiseeId;
  final String? franchiseeName;
  final int generation;
}

class SessionManager {
  int _generation = 0;
  SessionSnapshot? _activeSession;
  final Set<void Function()> _invalidationListeners = {};

  int get generation => _generation;
  SessionSnapshot? get current => _activeSession;

  SessionSnapshot activate({
    required String token,
    required String franchiseeId,
    String? userName,
    String? franchiseeName,
  }) {
    if (token.trim().isEmpty || franchiseeId.trim().isEmpty) {
      throw ArgumentError('An active session needs a token and franchisee.');
    }
    _generation += 1;
    return _activeSession = SessionSnapshot(
      token: token,
      userName: userName,
      franchiseeId: franchiseeId,
      franchiseeName: franchiseeName,
      generation: _generation,
    );
  }

  void addInvalidationListener(void Function() listener) {
    _invalidationListeners.add(listener);
  }

  void removeInvalidationListener(void Function() listener) {
    _invalidationListeners.remove(listener);
  }

  void invalidate() {
    _generation += 1;
    _activeSession = null;
    // Cache owners clear synchronously in this call stack, before logout
    // awaits preferences or the proxy providers receive a rebuild.
    for (final listener in List<void Function()>.from(_invalidationListeners)) {
      listener();
    }
    // Image providers are asynchronous visible caches too. Clear both pending
    // and live entries before logout performs any awaited preference work.
    // This is idempotent in the running app and also supplies a painting
    // binding for non-widget service callers before touching the image cache.
    WidgetsFlutterBinding.ensureInitialized();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  bool isCurrent(SessionSnapshot snapshot) {
    final current = _activeSession;
    return current != null &&
        current.generation == snapshot.generation &&
        current.token == snapshot.token &&
        current.franchiseeId == snapshot.franchiseeId;
  }
}

class StaleSessionException implements Exception {
  const StaleSessionException();

  @override
  String toString() => 'This operation belongs to a signed-out session.';
}
