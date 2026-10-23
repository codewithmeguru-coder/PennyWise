// Read-only replay of a PennyWise Firestore backup through the Phase 3
// categorisation and the Ziidi matcher. It reads one local JSON file and
// writes one Markdown report; it never talks to Firebase.
//
//   dart run tool/replay_backup.dart <backup.json> <report.md>
//
// People's names are never printed. Only names that clearly belong to a
// business (they contain a word like LTD, BANK or SUPERMARKET) are shown;
// all other names are counted, not listed.

import 'dart:convert';
import 'dart:io';

import 'package:pennywise/categorization/category_suggester.dart';
import 'package:pennywise/maintenance/ziidi_matcher.dart';
import 'package:pennywise/models/transaction_model.dart';
import 'package:pennywise/sms/sms_parser.dart';
import 'package:pennywise/sms/sms_transaction.dart';

const fixedCategory = {
  TransactionType.transfer: 'transfer',
  TransactionType.savingsContribution: 'savings',
  TransactionType.savingsWithdrawal: 'savings_withdrawal',
  TransactionType.debtRepayment: 'debt_repayment',
};

class Row {
  Row(this.doc);
  final Map<String, dynamic> doc;
  Map<String, dynamic> get f => doc['fields'] as Map<String, dynamic>;
  String get name => doc['name'] as String;
  String get account => name.split('/users/')[1].split('/')[0];
  String get id => name.split('/').last;
  String? s(String k) => (f[k] as Map?)?['stringValue'] as String?;
  DateTime? t(String k) => switch ((f[k] as Map?)?['timestampValue']) {
        final String v => DateTime.parse(v),
        _ => null,
      };
  double get amount {
    final v = f['amount'] as Map;
    return (v['doubleValue'] ?? num.parse('${v['integerValue']}')).toDouble();
  }

  bool get edited => t('updatedAt') != t('createdAt');
}

class Proposal {
  Proposal(this.row, this.type, this.category, this.suggestion, this.sms);
  final Row row;
  final String type;
  final String category;
  final Suggestion? suggestion;
  final SmsTransaction? sms;
}

/// Words that show a name belongs to a business, not a person.
final _business = RegExp(
    r'\b(LTD|LIMITED|PLC|BANK|C2B|B2C|PAYBILL|ACCOUNT|KCB|EQUITY|NCBA|'
    r'SAFARICOM|SUPERMARKET|SHOP|STORES?|ENTERPRISES?|SERVICES|HOTEL|'
    r'COSMETICS|CELLULANT|MART|SACCO|SCHOOL|HOSPITAL|PHARMACY|CHEMIST)\b',
    caseSensitive: false);

bool isBusinessName(String? name) => name != null && _business.hasMatch(name);

String ksh(double v) {
  final whole = v.abs().round().toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '${v < 0 ? '-' : ''}KSh $whole';
}

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/replay_backup.dart <backup.json> <report.md>');
    exit(64);
  }
  final backup = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final docs = (backup['collections']['transactions'] as List)
      .cast<Map<String, dynamic>>()
      .map(Row.new)
      .toList();
  const suggester = CategorySuggester();
  final out = StringBuffer()
    ..writeln('# Phase 3 stage 1: read-only replay report')
    ..writeln()
    ..writeln('Source: `${args[0].split(RegExp(r'[\\/]')).last}`, exported '
        '${backup['exportedAt']}. Nothing was written to Firestore; this only '
        'shows what the new rules **would** choose. People\'s names are not '
        'shown.')
    ..writeln();

  final accounts = docs.map((r) => r.account).toSet().toList()..sort();
  for (final account in accounts) {
    final rows = docs.where((r) => r.account == account).toList();
    final proposals = <Proposal>[];
    for (final r in rows) {
      final sms = r.s('smsText');
      final source = r.s('source');
      SmsTransaction? parsed;
      if (sms != null && source != null) {
        parsed = SmsParser.parse(
            sender: source == 'airtel' ? 'AIRTELMONEY' : 'MPESA',
            body: sms,
            date: r.t('date') ?? DateTime(2000));
      }
      if (parsed == null || r.edited) {
        proposals.add(Proposal(r, r.s('type')!, r.s('category')!, null, parsed));
        continue;
      }
      final type = parsed.type;
      final suggestion = suggester.forSms(parsed);
      final category = fixedCategory[type] ??
          (suggestion.isApplied
              ? suggestion.categoryId
              : type.isMoneyIn
                  ? CategorySuggester.uncategorizedIncome
                  : CategorySuggester.uncategorized);
      proposals.add(Proposal(r, type.wireName, category, suggestion, parsed));
    }

    final sms = proposals.where((p) => p.sms != null && !p.row.edited).toList();
    final manual = rows.where((r) => r.s('smsText') == null).length;
    final editedSms = proposals.where((p) => p.sms != null && p.row.edited).length;
    final byConf = <Confidence, int>{};
    for (final p in sms) {
      byConf.update(p.suggestion!.confidence, (c) => c + 1, ifAbsent: () => 1);
    }
    final storedUnc = rows
        .where((r) => (r.s('category') ?? '').startsWith('uncategorized'))
        .length;
    final newUnc = proposals.where((p) => p.category.startsWith('uncategorized')).length;

    out
      ..writeln('## Account ${account.substring(0, 6)}…')
      ..writeln()
      ..writeln('${rows.length} transactions: ${sms.length} SMS imports '
          'replayed, $editedSms SMS imports edited by you (kept as they are), '
          '$manual manual entries (never changed).')
      ..writeln()
      ..writeln('| Confidence | SMS transactions | Meaning |')
      ..writeln('| --- | --- | --- |')
      ..writeln('| High | ${byConf[Confidence.high] ?? 0} | Clear from the message or a known business |')
      ..writeln('| Medium | ${byConf[Confidence.medium] ?? 0} | A keyword; would be marked "Suggested" |')
      ..writeln('| Low | ${byConf[Confidence.low] ?? 0} | Needs review: not guessed |')
      ..writeln()
      ..writeln('"Uncategorized" would drop from **$storedUnc** to **$newUnc**.')
      ..writeln();

    // Proposed changes (type or category differs from what is stored).
    final changes = <String, int>{};
    for (final p in sms) {
      final from = '${p.row.s('type')} / ${p.row.s('category')}';
      final to = '${p.type} / ${p.category}';
      if (from == to) continue;
      final key = '$from → $to (${p.suggestion!.confidence.name})';
      changes.update(key, (c) => c + 1, ifAbsent: () => 1);
    }
    out
      ..writeln('### Proposed changes (type / category), not applied')
      ..writeln()
      ..writeln('| From | To | Confidence | Count |')
      ..writeln('| --- | --- | --- | --- |');
    final sorted = changes.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      final m = RegExp(r'^(.*) → (.*) \((\w+)\)$').firstMatch(e.key)!;
      out.writeln('| ${m[1]} | ${m[2]} | ${m[3]} | ${e.value} |');
    }
    out.writeln();

    // Needs review, grouped by reason; businesses named, people counted.
    final review = sms.where((p) => p.suggestion!.confidence == Confidence.low);
    final reasons = <String, List<Proposal>>{};
    for (final p in review) {
      reasons.putIfAbsent(p.suggestion!.reason, () => []).add(p);
    }
    out
      ..writeln('### Needs review (${review.length}): why each is uncertain')
      ..writeln()
      ..writeln('| Reason | Count | Examples |')
      ..writeln('| --- | --- | --- |');
    for (final e in reasons.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length))) {
      final names = <String, int>{};
      final others = <String>{};
      for (final p in e.value) {
        final n = p.sms!.counterparty;
        if (isBusinessName(n)) {
          names.update(n!, (c) => c + 1, ifAbsent: () => 1);
        } else {
          others.add(n ?? '');
        }
      }
      final shown = (names.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .take(6)
          .map((n) => '${n.key} (${n.value})');
      final examples = [
        ...shown,
        if (others.isNotEmpty)
          '${others.length} other ${others.length == 1 ? 'name' : 'names'} '
              'that look like people or small traders (not shown)',
      ].join(', ');
      out.writeln('| ${e.key} | ${e.value.length} | $examples |');
    }
    out.writeln();

    // Medium: list the keyword matches so they can be checked.
    final medium = sms.where((p) => p.suggestion!.confidence == Confidence.medium);
    if (medium.isNotEmpty) {
      final names = <String, int>{};
      for (final p in medium) {
        names.update('${p.sms!.counterparty} → ${p.category} (${p.suggestion!.reason})',
            (c) => c + 1, ifAbsent: () => 1);
      }
      out
        ..writeln('### Medium-confidence suggestions to check')
        ..writeln();
      for (final n in names.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
        out.writeln('- ${n.key}: ${n.value}');
      }
      out.writeln();
    }

    // Ziidi.
    final checks = rows
        .map((r) => (
              r,
              ZiidiMatcher.check(StoredSmsRecord(
                id: r.id,
                type: r.s('type')!,
                source: r.s('source'),
                reference: r.s('reference'),
                smsText: r.s('smsText'),
                createdAt: r.t('createdAt'),
                updatedAt: r.t('updatedAt'),
                hasReclassifiedFrom: r.f.containsKey('reclassifiedFrom'),
              ))
            ))
        .toList();
    final ziidi = checks.where((c) => c.$2.isZiidi).toList();
    final toChange = ziidi.where((c) => c.$2.change).toList();
    double sum(Iterable<(Row, ZiidiCheck)> xs, ZiidiDirection d) => xs
        .where((c) => c.$2.direction == d)
        .fold(0.0, (s, c) => s + c.$1.amount);
    final skipped = <String, int>{};
    for (final c in ziidi.where((c) => !c.$2.change)) {
      skipped.update(c.$2.reason!, (n) => n + 1, ifAbsent: () => 1);
    }
    final advert = checks
        .where((c) => c.$2.reason == 'Ziidi only mentioned in an advert')
        .length;
    final ones = toChange.where((c) => c.$1.amount == 1.0).length;
    out
      ..writeln('### Ziidi (exact SMS wording only)')
      ..writeln()
      ..writeln('| | Count | Amount |')
      ..writeln('| --- | --- | --- |')
      ..writeln('| Sent to Ziidi (would become savings contribution) | '
          '${toChange.where((c) => c.$2.direction == ZiidiDirection.sent).length} '
          '| ${ksh(sum(toChange, ZiidiDirection.sent))} |')
      ..writeln('| … of which KSh 1 automatic saves | $ones | ${ksh(ones.toDouble())} |')
      ..writeln('| Received from Ziidi (would become savings withdrawal) | '
          '${toChange.where((c) => c.$2.direction == ZiidiDirection.received).length} '
          '| ${ksh(sum(toChange, ZiidiDirection.received))} |');
    for (final s in skipped.entries) {
      out.writeln('| Ziidi, skipped: ${s.key} | ${s.value} | |');
    }
    out
      ..writeln('| Excluded: Ziidi only in an advert | $advert | |')
      ..writeln();

    // Before / after totals by category.
    Map<String, double> totals(Iterable<(String, String, double)> xs) {
      final m = <String, double>{};
      for (final (type, cat, amt) in xs) {
        m.update('$type|$cat', (v) => v + amt, ifAbsent: () => amt);
      }
      return m;
    }

    final before = totals(rows.map((r) => (r.s('type')!, r.s('category')!, r.amount)));
    final after = totals(proposals.map((p) => (p.type, p.category, p.row.amount)));
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    out
      ..writeln('### Totals by type and category: stored now vs proposed')
      ..writeln()
      ..writeln('Amounts exclude fees. "Proposed" applies the new rules to '
          'unedited SMS imports only.')
      ..writeln()
      ..writeln('| Type | Category | Now | Proposed | Change |')
      ..writeln('| --- | --- | --- | --- | --- |');
    for (final k in keys) {
      final b = before[k] ?? 0, a = after[k] ?? 0;
      if (b == 0 && a == 0) continue;
      final parts = k.split('|');
      out.writeln('| ${parts[0]} | ${parts[1]} | ${ksh(b)} | ${ksh(a)} | '
          '${a == b ? '' : ksh(a - b)} |');
    }
    out.writeln();
  }

  File(args[1]).writeAsStringSync(out.toString());
  stdout.writeln('Report written to ${args[1]}');
}
