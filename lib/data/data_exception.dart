import 'package:cloud_firestore/cloud_firestore.dart';

/// Thrown by repositories with a message that is safe to show to the user.
class DataException implements Exception {
  const DataException(this.message);

  /// Converts any error from Firestore into a [DataException].
  factory DataException.from(Object error) {
    if (error is DataException) return error;
    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return const DataException(
              'You don\'t have permission to access this data.');
        case 'unavailable':
        case 'deadline-exceeded':
          return const DataException(
              'Can\'t reach the server. Check your connection and try again.');
        case 'not-found':
          return const DataException('That item no longer exists.');
      }
    }
    return const DataException('Something went wrong. Please try again.');
  }

  final String message;

  @override
  String toString() => message;
}
