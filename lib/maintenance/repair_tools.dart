import '../services/auth_service.dart';

/// Who sees the one-off repair tools in Settings (Fix old Ziidi records,
/// Fix moves between your accounts).
///
/// They correct records saved by earlier versions of PennyWise, so only
/// profiles created before this release can have anything for them to do.
/// The creation time comes from Firebase Auth, not from the phone, and the
/// tools still only ever touch the signed-in user's own records (the
/// Firestore rules allow nothing else). New profiles don't see them.
///
/// Notes that point to a tool (e.g. a top-up into Equity to turn into a
/// move) still open it for anyone the note applies to.
class RepairTools {
  RepairTools._();

  /// Profiles created before this have records from earlier versions.
  static final cutoff = DateTime.utc(2026, 11, 1);

  static bool shownTo(AppUser? user) {
    final created = user?.createdAt;
    return created != null && created.isBefore(cutoff);
  }
}
