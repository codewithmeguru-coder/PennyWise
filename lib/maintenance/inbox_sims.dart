import '../sms/sms_gateway.dart';
import '../sms/sms_parser.dart';

/// Which SIM received each M-Pesa / Airtel message, by transaction code,
/// from the phone's own SMS records (Android reports the SIM per message).
///
/// A code seen on both SIMs, or with no SIM, gives no answer (null): the
/// SIM is never guessed. With no inbox access the map is empty.
Future<Map<String, int?>> simsByCode(SmsGateway gateway, DateTime since) async {
  final out = <String, int?>{};
  try {
    final inbox = await gateway.readInbox(
      senders: SmsParser.allSenders,
      since: since.subtract(const Duration(days: 1)),
    );
    for (final m in inbox) {
      final parsed = SmsParser.parse(
        sender: m.sender,
        body: m.body,
        date: m.date,
      );
      if (parsed == null) continue;
      final code = parsed.reference;
      out[code] = out.containsKey(code) && out[code] != m.simSlot
          ? null
          : m.simSlot;
    }
  } catch (_) {
    // No inbox access: no SIM evidence; SIMs stay unknown.
  }
  return out;
}
