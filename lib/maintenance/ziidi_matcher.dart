/// Finds stored M-Pesa transactions that were money moved into or out of
/// Ziidi (Safaricom's money-market fund), for the opt-in history fix.
///
/// Read-only: this only decides; it never writes. Pure Dart, so the offline
/// replay can run it on a backup file.
///
/// A record matches **only** by the exact M-Pesa sentence, never by amount:
///   "<code> Confirmed. Ksh1.00 sent to ZIIDI on 9/10/26 …"
///   "<code> Confirmed.You have received Ksh500.00 from ZIIDI on …"
/// Messages that only mention Ziidi in an advert ("Invest & earn daily
/// interest with ZIIDI …") do not match.
class ZiidiMatcher {
  ZiidiMatcher._();

  static const _code = r'^[A-Z0-9*]{10}\s+confirmed\.?\s*';
  static const _amount = r'ksh\s?[\d,]+(?:\.\d{1,2})?';

  static final _sent = RegExp(
      _code + _amount + r'\s+sent\s+to\s+ZIIDI\s+on\s+\d',
      caseSensitive: false);
  static final _received = RegExp(
      _code + r'you\s+have\s+received\s+' + _amount + r'\s+from\s+ZIIDI\s+on\s+\d',
      caseSensitive: false);

  /// Which way the money went, or null if [smsText] isn't a Ziidi transfer.
  static ZiidiDirection? directionOf(String smsText) {
    final text = smsText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_sent.hasMatch(text)) return ZiidiDirection.sent;
    if (_received.hasMatch(text)) return ZiidiDirection.received;
    return null;
  }

  /// Whether [record] should be changed by the fix, and if not, why.
  static ZiidiCheck check(StoredSmsRecord record) {
    final text = record.smsText;
    if (text == null) return const ZiidiCheck.notZiidi('Not from an SMS');
    final direction = directionOf(text);
    if (direction == null) {
      return text.toUpperCase().contains('ZIIDI')
          ? const ZiidiCheck.notZiidi('Ziidi only mentioned in an advert')
          : const ZiidiCheck.notZiidi('Not a Ziidi transaction');
    }
    final expectedType = direction == ZiidiDirection.sent ? 'expense' : 'income';

    if (record.source != 'mpesa' ||
        record.reference == null ||
        record.id != 'mpesa_${record.reference}') {
      return ZiidiCheck.skipped(direction, 'Not an M-Pesa SMS import');
    }
    if (record.hasReclassifiedFrom) {
      return ZiidiCheck.skipped(direction, 'Already fixed');
    }
    if (record.type != expectedType) {
      return ZiidiCheck.skipped(direction,
          'Already recorded as ${record.type.replaceAll('_', ' ')}');
    }
    if (record.createdAt == null ||
        record.updatedAt == null ||
        record.updatedAt != record.createdAt) {
      return ZiidiCheck.skipped(direction, 'Edited by you after import');
    }
    return ZiidiCheck.change(direction);
  }
}

enum ZiidiDirection {
  /// Into Ziidi: becomes a savings contribution.
  sent,

  /// Out of Ziidi: becomes a savings withdrawal.
  received,
}

/// The decision for one record.
class ZiidiCheck {
  const ZiidiCheck._(this.direction, this.change, this.reason);

  const ZiidiCheck.change(ZiidiDirection direction)
      : this._(direction, true, null);
  const ZiidiCheck.skipped(ZiidiDirection direction, String reason)
      : this._(direction, false, reason);
  const ZiidiCheck.notZiidi(String reason) : this._(null, false, reason);

  /// Null if the record isn't a Ziidi transfer at all.
  final ZiidiDirection? direction;

  /// True if the fix would change this record.
  final bool change;

  /// Why it is skipped, or why it isn't Ziidi.
  final String? reason;

  bool get isZiidi => direction != null;

  /// The new stored type and category if [change] is true.
  String? get newType => !change
      ? null
      : direction == ZiidiDirection.sent
          ? 'savings_contribution'
          : 'savings_withdrawal';

  String? get newCategory => !change
      ? null
      : direction == ZiidiDirection.sent
          ? 'savings'
          : 'savings_withdrawal';
}

/// The stored fields the matcher needs (from Firestore or a backup).
class StoredSmsRecord {
  const StoredSmsRecord({
    required this.id,
    required this.type,
    this.source,
    this.reference,
    this.smsText,
    this.createdAt,
    this.updatedAt,
    this.hasReclassifiedFrom = false,
  });

  final String id;

  /// Stored type name, e.g. "expense".
  final String type;
  final String? source;
  final String? reference;
  final String? smsText;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool hasReclassifiedFrom;
}
