import '../models/transaction_model.dart';
import 'sms_transaction.dart';

/// Turns M-Pesa and Airtel Money SMS messages into [SmsTransaction]s.
///
/// Pure Dart (no Android code), so it can be unit-tested with sample
/// messages. Anything that doesn't clearly look like a completed transaction
/// returns null and is ignored: promotions, failed transactions, OTPs,
/// balance enquiries, and every SMS from any other sender.
class SmsParser {
  SmsParser._();

  /// Sender ids allowed per service, normalised with [normalizeSender].
  ///
  /// The Android side receives this list and drops every other SMS before it
  /// ever reaches Dart, so personal messages are never read by the app.
  static const Map<TransactionSource, List<String>> senders = {
    TransactionSource.mpesa: ['MPESA'],
    TransactionSource.airtel: ['AIRTELMONEY', 'AIRTEL'],
    TransactionSource.equity: ['EQUITYBANK'],
  };

  /// Every allowed sender id, for the Android filter.
  static List<String> get allSenders =>
      [for (final ids in senders.values) ...ids];

  /// "M-PESA", "m pesa" and "MPESA" all become "MPESA".
  /// Kept identical to `normalize()` in SmsBridge.kt.
  static String normalizeSender(String address) =>
      address.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Which service [address] belongs to, or null for anyone else.
  static TransactionSource? sourceFor(String address) {
    final normalized = normalizeSender(address);
    for (final entry in senders.entries) {
      if (entry.value.contains(normalized)) return entry.key;
    }
    return null;
  }

  /// Parses one SMS. Returns null if it isn't a transaction we understand.
  ///
  /// [date] is the phone's timestamp for the SMS; it's used as the
  /// transaction date because the date format inside the text varies.
  static SmsTransaction? parse({
    required String sender,
    required String body,
    required DateTime date,
  }) {
    final source = sourceFor(sender);
    if (source == null) return null;

    // SMS bodies sometimes contain line breaks or double spaces.
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_failed.hasMatch(text)) return null;

    final parsed = switch (source) {
      TransactionSource.mpesa => _parseMpesa(text),
      TransactionSource.airtel => _parseAirtel(text),
      TransactionSource.equity => _parseEquity(text, date),
      TransactionSource.manual => null,
    };
    if (parsed == null || parsed.amount <= 0) return null;

    return SmsTransaction(
      source: source,
      kind: parsed.kind,
      amount: parsed.amount,
      reference: parsed.reference,
      date: date,
      counterparty: parsed.counterparty,
      phone: parsed.phone,
      account: parsed.account,
      fee: parsed.fee,
      currency: parsed.currency,
      viaMobileMoney: parsed.viaMobileMoney,
      maskedText: maskDigits(text),
    );
  }

  // ---- M-Pesa ------------------------------------------------------------

  // Every M-Pesa transaction SMS starts with a 10-character code, then
  // "Confirmed", e.g. "SJK3ABC123 Confirmed. Ksh500.00 paid to ...".
  static final _mpesaCode =
      RegExp(r'^([A-Z0-9]{10})\s+confirmed', caseSensitive: false);

  // One pattern per kind of message. The first group is always the amount.
  static final _mpesaReceived = RegExp(
      r'received\s+' + _ksh + r'\s+from\s+(.+?)\s+on\s+\d',
      caseSensitive: false);
  static final _mpesaPaid = RegExp(
      _ksh + r'\s+paid\s+to\s+(.+?)\.?\s+on\s+\d',
      caseSensitive: false);
  static final _mpesaSent = RegExp(
      _ksh + r'\s+sent\s+to\s+(.+?)(?:\s+for\s+account\s+(\S+))?\s+on\s+\d',
      caseSensitive: false);
  static final _mpesaWithdraw = RegExp(
      r'withdraw\s+' + _ksh + r'\s+from\s+(.+?)\s+new\s+m-?pesa',
      caseSensitive: false);
  static final _mpesaDeposit = RegExp(
      r'give\s+' + _ksh + r'\s+cash\s+to\s+(.+?)\s+new\s+m-?pesa',
      caseSensitive: false);
  // "You bought Ksh50.00 of airtime [for 254712345678] on …": the number is
  // there only when it was for someone else.
  static final _mpesaAirtime = RegExp(
      r'bought\s+' + _ksh + r'\s+of\s+airtime(?:\s+for\s+(\+?\d{9,12}))?',
      caseSensitive: false);
  // "Fuliza M-PESA amount is Ksh 50.00. Access Fee charged Ksh 0.50."
  static final _fulizaDraw = RegExp(
      r'^\S+\s+confirmed\.?\s*fuliza\s+m-?pesa\s+amount\s+is\s+' + _ksh +
          r'\.?\s+access\s+fee\s+charged\s+' + _ksh,
      caseSensitive: false);
  // "Ksh 300.00 from your M-PESA has been used to fully (or partially) pay
  // your outstanding Fuliza M-PESA."
  static const _fulizaRepaid =
      r'\s+from\s+your\s+m-?pesa\s+has\s+been\s+used\s+to\s+'
      r'(?:fully|partially)\s+pay\s+your\s+outstanding\s+fuliza';
  static final _fulizaRepayment = RegExp(
      r'^\S+\s+confirmed\.?\s*' + _ksh + _fulizaRepaid,
      caseSensitive: false);

  /// True if [body] looks like a completed M-Pesa / Airtel transaction
  /// (a transaction code, then "Confirmed"), whether or not PennyWise can
  /// read the rest. Used to report messages it couldn't read.
  static bool looksLikeTransaction({
    required String sender,
    required String body,
  }) {
    final source = sourceFor(sender);
    if (source == null) return false;
    final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_failed.hasMatch(text)) return false;
    return switch (source) {
      TransactionSource.mpesa => _mpesaCode.hasMatch(text),
      TransactionSource.airtel => _airtelLeadingId.hasMatch(text) ||
          _airtelId.hasMatch(text),
      TransactionSource.equity => _equityLooksLike.hasMatch(text),
      TransactionSource.manual => false,
    };
  }

  static _Parsed? _parseMpesa(String text) {
    final code = _mpesaCode.firstMatch(text);
    if (code == null) return null;
    final reference = code.group(1)!.toUpperCase();
    final fee = _amount(_fee.firstMatch(text)?.group(1));

    _Parsed result(SmsTransactionKind kind, RegExpMatch m,
            {String? who, String? account}) =>
        _Parsed(
          kind: kind,
          reference: reference,
          amount: _amount(m.group(1)) ?? 0,
          counterparty: who == null ? null : _cleanName(who),
          phone: who == null ? null : _phone.firstMatch(who)?.group(0),
          account: account,
          fee: fee,
        );

    // Fuliza first: these never contain "paid to" / "received", but are
    // checked before the general patterns so nothing else claims them.
    if (_fulizaDraw.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.fulizaDraw,
        reference: reference,
        amount: _amount(m.group(1)) ?? 0,
        counterparty: 'Fuliza M-Pesa',
        fee: _amount(m.group(2)),
      );
    }
    if (_fulizaRepayment.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.fulizaRepayment,
        reference: reference,
        amount: _amount(m.group(1)) ?? 0,
        counterparty: 'Fuliza M-Pesa',
      );
    }

    // Order matters: "received" before "sent", since a received message can
    // never say "sent to", but checking the specific ones first is clearer.
    if (_mpesaReceived.firstMatch(text) case final m?) {
      return result(SmsTransactionKind.received, m, who: m.group(2));
    }
    if (_mpesaAirtime.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.airtime,
        reference: reference,
        amount: _amount(m.group(1)) ?? 0,
        phone: m.group(2),
        fee: fee,
      );
    }
    if (_mpesaWithdraw.firstMatch(text) case final m?) {
      return result(SmsTransactionKind.withdrawal, m, who: m.group(2));
    }
    if (_mpesaDeposit.firstMatch(text) case final m?) {
      return result(SmsTransactionKind.deposit, m, who: m.group(2));
    }
    if (_mpesaPaid.firstMatch(text) case final m?) {
      return result(SmsTransactionKind.payment, m, who: m.group(2));
    }
    if (_mpesaSent.firstMatch(text) case final m?) {
      final account = m.group(3);
      final who = m.group(2)!;
      // "sent to KPLC PREPAID for account 1234" is a Paybill payment;
      // "sent to JOHN DOE 0712345678" is a transfer to a person.
      final kind = account != null || _phone.firstMatch(who) == null
          ? SmsTransactionKind.payment
          : SmsTransactionKind.sent;
      return result(kind, m, who: who, account: account);
    }
    return null; // e.g. M-Shwari / Fuliza / reversal: not handled yet
  }

  // ---- Airtel Money ------------------------------------------------------

  // Airtel's wording differs between countries and has changed over time,
  // so these patterns are looser than M-Pesa's. A message still needs an
  // explicit transaction id AND an amount AND a transaction verb.
  static final _airtelId = RegExp(
      r'(?:trans(?:action)?\.?\s*id|txn\s*id|tid|ref(?:erence)?)\s*[:.]?\s*'
      r'([A-Z0-9][A-Z0-9.]{5,38})',
      caseSensitive: false);
  static final _airtelLeadingId =
      RegExp(r'^([A-Z0-9][A-Z0-9.]{5,38})\s+confirmed', caseSensitive: false);
  static final _airtelAmount = RegExp(_ksh, caseSensitive: false);
  static final _airtelFrom = RegExp(
      r'\bfrom\s+(.+?)(?:\s+on\s+\d|\.\s|,|\s+new\s+bal|\s+your\s+bal|$)',
      caseSensitive: false);
  static final _airtelTo = RegExp(
      r'\bto\s+(.+?)(?:\s+on\s+\d|\.\s|,|\s+new\s+bal|\s+your\s+bal|$)',
      caseSensitive: false);

  static _Parsed? _parseAirtel(String text) {
    final idMatch =
        _airtelLeadingId.firstMatch(text) ?? _airtelId.firstMatch(text);
    final amount = _amount(_airtelAmount.firstMatch(text)?.group(1));
    if (idMatch == null || amount == null) return null;
    // Drop a trailing full stop that ended the sentence, not the id.
    final reference = idMatch.group(1)!.replaceAll(RegExp(r'\.+$'), '');
    if (reference.length < 6) return null;

    final lower = text.toLowerCase();
    final SmsTransactionKind kind;
    String? who;
    if (lower.contains('received')) {
      kind = SmsTransactionKind.received;
      who = _airtelFrom.firstMatch(text)?.group(1);
    } else if (lower.contains('withdraw')) {
      kind = SmsTransactionKind.withdrawal;
      who = _airtelFrom.firstMatch(text)?.group(1);
    } else if (lower.contains('deposit')) {
      kind = SmsTransactionKind.deposit;
      who = _airtelTo.firstMatch(text)?.group(1) ??
          _airtelFrom.firstMatch(text)?.group(1);
    } else if (lower.contains('airtime') || lower.contains('bundle')) {
      kind = SmsTransactionKind.airtime;
    } else if (lower.contains('paid') || lower.contains('payment')) {
      kind = SmsTransactionKind.payment;
      who = _airtelTo.firstMatch(text)?.group(1);
    } else if (lower.contains('sent')) {
      who = _airtelTo.firstMatch(text)?.group(1);
      kind = who != null && _phone.hasMatch(who)
          ? SmsTransactionKind.sent
          : SmsTransactionKind.payment;
    } else {
      return null; // no transaction verb: not a transaction notification
    }

    return _Parsed(
      kind: kind,
      reference: reference.toUpperCase(),
      amount: amount,
      counterparty: who == null ? null : _cleanName(who),
      phone: who == null ? null : _phone.firstMatch(who)?.group(0),
      fee: _amount(_fee.firstMatch(text)?.group(1)),
    );
  }

  // ---- Equity Bank -------------------------------------------------------

  // Only messages about the user's own Equity account. Receipts Equity
  // sends for M-Pesa payments into other people's accounts or tills ("…has
  // been credited to…", "…has sent KShs. … to your MPESA", "…deposited to
  // Equity Account in favor of…", "Payment of KES. … Till No.", "Bill
  // payment to…") match nothing here: the M-Pesa message already records
  // them, so they are ignored rather than counted twice.

  // "CONFIRMED. USD 20.00, Auth for card 1234..5678 at GOOGLE*ADS on
  // 2026-03-12 15:52:10 Ref:123456789012."
  static final _equityCard = RegExp(
      r'^confirmed\.?\s+([a-z]{3})\s+([\d,]+(?:\.\d+)?),\s*auth\s+for\s+card\s+'
      r'\S+\s+at\s+(.+?)\s+on\s+\d{4}-\d\d-\d\d\s+[\d:]+\s+ref:\s*(\w+)',
      caseSensitive: false);
  // "Txn: A fee has been deducted from your account Acct:… Amt:KES 300.00
  // Desc: Annual Debit Card Fee Date:11-09-2026 17:15:02"
  static final _equityFee = RegExp(
      r'a\s+fee\s+has\s+been\s+deducted\s+from\s+your\s+account.*?'
      r'amt:\s*kes\.?\s*([\d,]+(?:\.\d+)?)\s+desc:\s*(.+?)\s+date:\s*([\d\- :]+\d)',
      caseSensitive: false);
  // "Dear NAME KES 5000.00 has been drawn from your account 0123......4567
  // Ref:12345678 on 14-SEP-2026 09:50:01 AM."
  static final _equityDrawn = RegExp(
      r'kes\.?\s*([\d,]+(?:\.\d+)?)\s+has\s+been\s+drawn\s+from\s+your\s+'
      r'account\s+\S+\s+ref:\s*(\w+)',
      caseSensitive: false);
  // "1500.00 KES has been successfully sent to JOHN DOE 0********123. Ref.
  // ABC123 on 28 Oct 2025 at 19:18 EAT. Transaction charge 0.00 KES, SMS
  // alert charge 0.00 KES"
  static final _equitySent = RegExp(
      r'^([\d,]+(?:\.\d+)?)\s*kes\s+has\s+been\s+successfully\s+sent\s+to\s+'
      r'(.+?)\s+\d[\d*]*\.\s*ref\.?\s*(\w+)',
      caseSensitive: false);
  static final _equityCharges = RegExp(
      r'([\d,]+(?:\.\d+)?)\s*kes', caseSensitive: false);
  // "You have received 2000.00 KES from JOHN DOE 0********123 to your
  // Equity account 0********456. Ref. ABC123 on 30 Oct 2025 at 17:23 EAT"
  static final _equityReceived = RegExp(
      r'^you\s+have\s+received\s+([\d,]+(?:\.\d+)?)\s*kes\s+from\s+(.+?)\s+'
      r'\d[\d*]*\s+to\s+your\s+equity\s+account\s+\S+\s+ref\.?\s*(\w+)',
      caseSensitive: false);
  // "Confirmed. KES. 1,000.00 from JOHN DOE [Phone No. 2547…] received via
  // M-Pesa Ref. UJVHK7WQUD on …": paid into the account from mobile money.
  static final _equityViaMobile = RegExp(
      r'^confirmed\.?\s*kes\.?\s*([\d,]+(?:\.\d+)?)\s+from\s+(.+?)'
      r'(?:\s+phone\s+no\.?\s*\d+)?\s+received\s+via\s+(m-?pesa|airtel)\s+'
      r'ref\.?\s*(\w+)',
      caseSensitive: false);
  static final _equityLooksLike = RegExp(
      r'auth\s+for\s+card|fee\s+has\s+been\s+deducted|has\s+been\s+drawn|'
      r'successfully\s+sent\s+to|to\s+your\s+equity\s+account|received\s+via',
      caseSensitive: false);

  static _Parsed? _parseEquity(String text, DateTime date) {
    if (_equityCard.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.payment,
        reference: 'CARD${m.group(4)!}',
        amount: _amount(m.group(2)) ?? 0,
        counterparty: _cleanName(m.group(3)!.replaceAll('*', ' ')),
        currency: m.group(1)!.toUpperCase(),
      );
    }
    if (_equityFee.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.charge,
        // No reference in the SMS: the time it states is unique enough.
        reference: 'FEE${m.group(3)!.replaceAll(RegExp(r'\D'), '')}',
        amount: _amount(m.group(1)) ?? 0,
        counterparty: m.group(2)!.trim(),
      );
    }
    if (_equityDrawn.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.withdrawal,
        reference: m.group(2)!.toUpperCase(),
        amount: _amount(m.group(1)) ?? 0,
        counterparty: 'Equity Bank',
      );
    }
    if (_equitySent.firstMatch(text) case final m?) {
      final charges = text.toLowerCase().contains('charge')
          ? _equityCharges
              .allMatches(text.substring(m.end))
              .map((c) => _amount(c.group(1)) ?? 0)
              .fold(0.0, (a, b) => a + b)
          : 0.0;
      return _Parsed(
        kind: SmsTransactionKind.sent,
        reference: m.group(3)!.toUpperCase(),
        amount: _amount(m.group(1)) ?? 0,
        counterparty: _cleanName(m.group(2)!),
        fee: charges > 0 ? charges : null,
      );
    }
    if (_equityReceived.firstMatch(text) case final m?) {
      return _Parsed(
        kind: SmsTransactionKind.received,
        reference: m.group(3)!.toUpperCase(),
        amount: _amount(m.group(1)) ?? 0,
        counterparty: _cleanName(m.group(2)!),
      );
    }
    if (_equityViaMobile.firstMatch(text) case final m?) {
      final code = m.group(4)!.toUpperCase();
      return _Parsed(
        kind: SmsTransactionKind.received,
        reference: code,
        amount: _amount(m.group(1)) ?? 0,
        counterparty: _cleanName(m.group(2)!),
        viaMobileMoney: code,
      );
    }
    return null;
  }

  // ---- Shared helpers ----------------------------------------------------

  /// "Ksh1,500.00", "KES 1500", "Kshs. 20" -> group 1 is the number.
  static const _ksh = r'(?:ksh|kes|kshs)\.?\s?([\d,]+(?:\.\d{1,2})?)';

  static final _fee = RegExp(
      r'(?:transaction\s+cost|cost|charges?|fee)\s*,?\s*:?\s*'
      r'(?:ksh|kes|kshs)\.?\s?([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false);

  static final _failed = RegExp(
      r'\bfailed\b|\binsufficient\b|\bwrong pin\b|\bnot\s+successful\b',
      caseSensitive: false);

  /// Kenyan mobile numbers: 07xx / 01xx / 2547xx / +2547xx, or already
  /// partly masked by the provider (e.g. 0712***678).
  static final _phone =
      RegExp(r'(?:\+?254|0)[17][\d*]{8}');

  static double? _amount(String? raw) =>
      raw == null ? null : double.tryParse(raw.replaceAll(',', ''));

  /// "NAIVAS WESTLANDS 0712345678." -> "Naivas Westlands".
  /// "123456 - JOHN AGENT" -> "John Agent".
  static String? _cleanName(String raw) {
    var name = raw
        .replaceAll(_phone, '')
        .replaceAll(RegExp(r'^\d+\s*-\s*'), '') // agent / till number prefix
        .replaceAll(RegExp(r'[\s.,;:-]+$'), '')
        .trim();
    if (name.isEmpty) return null;
    name = name
        .split(RegExp(r'\s+'))
        .map((w) => w.length <= 1
            ? w.toUpperCase()
            : w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
    return name.length > 80 ? name.substring(0, 80) : name;
  }

  /// Masks every run of 6+ digits, keeping the first 2 and last 3:
  /// "0712345678" -> "07*****678". Applied to the SMS text before it's
  /// stored, so phone and account numbers aren't saved in full.
  static String maskDigits(String text) =>
      text.replaceAllMapped(RegExp(r'\d{6,}'), (m) {
        final d = m.group(0)!;
        return d.substring(0, 2) +
            '*' * (d.length - 5) +
            d.substring(d.length - 3);
      });
}

/// Intermediate result while parsing one message.
class _Parsed {
  const _Parsed({
    required this.kind,
    required this.reference,
    required this.amount,
    this.counterparty,
    this.phone,
    this.account,
    this.fee,
    this.currency = 'KES',
    this.viaMobileMoney,
  });

  final SmsTransactionKind kind;
  final String currency;
  final String? viaMobileMoney;
  final String reference;
  final double amount;
  final String? counterparty;
  final String? phone;
  final String? account;
  final double? fee;
}
