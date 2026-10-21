import 'dart:async';

import 'package:pennywise/services/auth_service.dart';

/// What [FakeAuthService.signInWithGoogle] should do.
enum FakeGoogleOutcome { success, cancel, error }

/// In-memory [AuthService] so widget tests don't need Firebase.
class FakeAuthService implements AuthService {
  FakeAuthService({AppUser? signedInAs}) : _user = signedInAs;

  static const testUser = AppUser(uid: 'u1', email: 'test@example.com');

  /// The account the fake "Google" picker returns.
  static const googleUser = AppUser(
    uid: 'g1',
    email: 'ann@gmail.com',
    displayName: 'Ann Google',
  );

  final _controller = StreamController<AppUser?>.broadcast();
  AppUser? _user;

  /// When set, [signIn] and [register] throw it instead of succeeding.
  AuthException? nextError;

  FakeGoogleOutcome googleOutcome = FakeGoogleOutcome.success;
  int googleCalls = 0;

  @override
  Stream<AppUser?> get userChanges async* {
    yield _user;
    yield* _controller.stream;
  }

  @override
  AppUser? get currentUser => _user;

  void _set(AppUser? user) {
    _user = user;
    _controller.add(user);
  }

  @override
  Future<void> signIn({required String email, required String password}) async {
    if (nextError != null) throw nextError!;
    _set(AppUser(uid: 'u-$email', email: email));
  }

  @override
  Future<void> register({
    required String name,
    required String email,
    required String password,
  }) async {
    if (nextError != null) throw nextError!;
    _set(AppUser(uid: 'u-$email', email: email, displayName: name));
  }

  @override
  Future<bool> signInWithGoogle() async {
    googleCalls++;
    switch (googleOutcome) {
      case FakeGoogleOutcome.cancel:
        return false;
      case FakeGoogleOutcome.error:
        throw const AuthException(
            'Google sign-in failed. Check your connection and try again.');
      case FakeGoogleOutcome.success:
        _set(googleUser);
        return true;
    }
  }

  @override
  Future<void> signOut() async => _set(null);
}
