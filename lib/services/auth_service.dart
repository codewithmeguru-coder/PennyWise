import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// The signed-in user, as the rest of the app sees them.
///
/// Screens use this instead of Firebase's [User] so they (and tests) don't
/// depend on Firebase directly.
class AppUser {
  const AppUser({
    required this.uid,
    required this.email,
    this.displayName,
    this.photoUrl,
  });

  final String uid;
  final String email;
  final String? displayName;

  /// Profile picture (from Google). Null for email/password accounts.
  final String? photoUrl;
}

/// Thrown by [AuthService] with a message that is safe to show to the user.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything the app needs from authentication.
///
/// Passwords are only ever handed to Firebase Authentication, which stores
/// them hashed on its side. The app never saves them anywhere; the Firestore
/// profile at `users/{uid}` holds only the email and display name.
abstract class AuthService {
  /// Emits the current user on listen, then again on every sign-in,
  /// sign-out, or profile change. `null` means signed out.
  Stream<AppUser?> get userChanges;

  AppUser? get currentUser;

  Future<void> signIn({required String email, required String password});

  Future<void> register({
    required String name,
    required String email,
    required String password,
  });

  /// Signs in with a Google account picked from the device, creating the
  /// Firebase account the first time.
  ///
  /// Returns false if the user closed the account picker (not an error).
  /// Throws an [AuthException] if sign-in failed.
  Future<bool> signInWithGoogle();

  Future<void> signOut();
}

/// [AuthService] backed by Firebase Authentication (email/password).
class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, FirebaseFirestore? firestore})
      : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  @override
  Stream<AppUser?> get userChanges => _auth.userChanges().map(_toAppUser);

  @override
  AppUser? get currentUser => _toAppUser(_auth.currentUser);

  @override
  Future<void> signIn({required String email, required String password}) =>
      _guard(() async {
        final credential = await _auth.signInWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        // Not awaited: the user is signed in; this shouldn't hold the UI.
        unawaited(_saveProfile(credential.user));
      });

  @override
  Future<void> register({
    required String name,
    required String email,
    required String password,
  }) =>
      _guard(() async {
        final credential = await _auth.createUserWithEmailAndPassword(
          email: email.trim(),
          password: password,
        );
        // From here on the account exists and the user is signed in, so
        // nothing below may turn this into a failed registration (retrying
        // would only hit "email already in use").
        unawaited(_finishRegistration(credential.user, name.trim()));
      });

  /// Sets the display name, then saves the profile. Best-effort.
  Future<void> _finishRegistration(User? user, String name) async {
    if (user == null) return;
    try {
      await user.updateDisplayName(name);
      await user.reload(); // so displayName is up to date below
    } catch (e) {
      debugPrint('Could not set display name: $e');
    }
    await _saveProfile(_auth.currentUser ?? user);
  }

  /// google_sign_in must be initialised exactly once before use. Reset on
  /// failure so a later attempt can retry.
  Future<void>? _googleInit;

  Future<void> _initGoogle() => _googleInit ??= GoogleSignIn.instance
          // On Android the web client id comes from google-services.json
          // (the generated default_web_client_id resource), so none is
          // hardcoded here.
          .initialize()
          .catchError((Object e) {
        _googleInit = null;
        throw e;
      });

  @override
  Future<bool> signInWithGoogle() async {
    try {
      final UserCredential result;
      if (kIsWeb) {
        // The account picker isn't available on web; Firebase's popup is.
        result = await _auth.signInWithPopup(GoogleAuthProvider());
      } else {
        await _initGoogle();
        // Shows Google's account chooser (Credential Manager on Android).
        final account = await GoogleSignIn.instance.authenticate();
        final idToken = account.authentication.idToken;
        if (idToken == null) {
          throw const AuthException(
              'Google didn\'t return sign-in details. Please try again.');
        }
        // Signs in to the existing Firebase account for this Google account,
        // or creates it the first time. Firebase keeps one account per
        // email, so this never creates a duplicate.
        result = await _auth.signInWithCredential(
          GoogleAuthProvider.credential(idToken: idToken),
        );
      }
      // Name, email and photo come from the Google account via Firebase.
      unawaited(_saveProfile(result.user));
      return true;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      debugPrint('Google sign-in failed: ${e.code} ${e.description}');
      throw AuthException(_googleMessage(e));
    } on FirebaseAuthException catch (e) {
      // Web only: the user closed the popup.
      if (e.code == 'popup-closed-by-user' ||
          e.code == 'cancelled-popup-request') {
        return false;
      }
      debugPrint('Firebase Google sign-in failed: ${e.code} ${e.message}');
      throw AuthException(_googleFirebaseMessage(e.code));
    } on AuthException {
      rethrow;
    } catch (e) {
      debugPrint('Google sign-in failed: $e');
      throw const AuthException(
          'Google sign-in failed. Please try again.');
    }
  }

  static String _googleMessage(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.interrupted:
        return 'Google sign-in was interrupted. Please try again.';
      case GoogleSignInExceptionCode.uiUnavailable:
        return 'Couldn\'t open Google sign-in. Please try again.';
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return 'Google sign-in isn\'t set up correctly for this app yet.';
      default:
        // Android reports "no Google account on the device" this way — and
        // also an app whose SHA-1 isn't registered in Firebase.
        if ((e.description ?? '').contains('No credential')) {
          return 'No Google account was found. Add one in your device\'s '
              'Settings, then try again.';
        }
        return 'Google sign-in failed. Check your connection and try again.';
    }
  }

  /// Like [messageForCode], but worded for Google sign-in.
  static String _googleFirebaseMessage(String code) {
    switch (code) {
      case 'invalid-credential':
        return 'Google sign-in failed. Please try again.';
      case 'account-exists-with-different-credential':
        return 'An account with this email already exists. Sign in with your '
            'email and password instead.';
      case 'operation-not-allowed':
        return 'Google sign-in isn\'t enabled for this app yet.';
      default:
        return messageForCode(code);
    }
  }

  @override
  Future<void> signOut() => _guard(() async {
        await _auth.signOut();
        // Forget the chosen Google account so the picker shows next time.
        if (!kIsWeb && _googleInit != null) {
          try {
            await GoogleSignIn.instance.signOut();
          } catch (e) {
            debugPrint('Google sign-out failed: $e');
          }
        }
      });

  /// Creates or refreshes the `users/{uid}` profile document.
  ///
  /// Best-effort: the user is already signed in, and transactions don't
  /// depend on this document, so a failure is logged rather than shown.
  Future<void> _saveProfile(User? user) async {
    if (user == null) return;
    try {
      final ref = _firestore.collection('users').doc(user.uid);
      final profile = {
        'email': user.email,
        'displayName': user.displayName,
        'photoUrl': user.photoURL, // from Google; null for email accounts
        'updatedAt': FieldValue.serverTimestamp(),
      };
      final snapshot = await ref.get();
      if (snapshot.exists) {
        await ref.update(profile);
      } else {
        await ref.set({...profile, 'createdAt': FieldValue.serverTimestamp()});
      }
    } catch (e) {
      debugPrint('Could not save user profile: $e');
    }
  }

  static AppUser? _toAppUser(User? user) => user == null
      ? null
      : AppUser(
          uid: user.uid,
          email: user.email ?? '',
          displayName: user.displayName,
          photoUrl: user.photoURL,
        );

  /// Runs [action], converting Firebase errors into [AuthException]s.
  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on FirebaseAuthException catch (e) {
      throw AuthException(messageForCode(e.code));
    } catch (_) {
      throw const AuthException('Something went wrong. Please try again.');
    }
  }

  /// Maps a [FirebaseAuthException.code] to a user-friendly message.
  static String messageForCode(String code) {
    switch (code) {
      case 'invalid-email':
        return 'That email address doesn\'t look right.';
      case 'user-disabled':
        return 'This account has been disabled.';
      // Newer Firebase projects return 'invalid-credential' for both a wrong
      // password and an unknown email (email enumeration protection).
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';
      case 'email-already-in-use':
        return 'An account already exists for that email.';
      case 'weak-password':
        return 'Please choose a stronger password (at least 6 characters).';
      // The project's password policy (Firebase console) can be stricter.
      case 'password-does-not-meet-requirements':
        return "That password doesn't meet the requirements. Try a longer "
            'one with a mix of letters, numbers and symbols.';
      case 'missing-email':
        return 'Enter your email.';
      case 'missing-password':
        return 'Enter your password.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait a moment and try again.';
      case 'network-request-failed':
        return 'No internet connection. Check your network and try again.';
      case 'operation-not-allowed':
        return 'Email sign-in isn\'t enabled for this app yet.';
      default:
        return 'Something went wrong. Please try again.';
    }
  }
}
