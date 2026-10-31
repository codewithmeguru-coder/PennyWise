import 'dart:convert';
import 'dart:io';

/// Market exchange rates into Kenyan shillings, for card payments made in
/// another currency.
abstract class ExchangeRates {
  /// KES for one unit of [currency] (e.g. "USD") on [day], or null when it
  /// can't be found (offline, unknown currency).
  Future<double?> toKes(String currency, DateTime day);
}

/// Daily rates from the free, public fawazahmed0 currency-api (served by
/// jsDelivr, with Cloudflare as a fallback). Only the date and currency are
/// in the request: nothing about the user or the payment.
class OnlineExchangeRates implements ExchangeRates {
  OnlineExchangeRates({HttpClient Function()? client})
    : _client = client ?? HttpClient.new;

  final HttpClient Function() _client;
  final _cache = <String, double>{};

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Where to look, most exact first. A day's rates are published a little
  /// after it starts, so the latest ones stand in for the last two days.
  static List<Uri> urls(String currency, DateTime day, DateTime now) {
    final c = currency.toLowerCase();
    final d = _ymd(day);
    final recent = now.difference(day).inDays <= 2;
    return [
      Uri.parse(
        'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@$d/v1/currencies/$c.json',
      ),
      Uri.parse('https://$d.currency-api.pages.dev/v1/currencies/$c.json'),
      if (recent)
        Uri.parse(
          'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/$c.json',
        ),
    ];
  }

  /// The KES rate in one response: `{"date": "…", "usd": {"kes": 129.2}}`.
  static double? parse(String currency, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final rates = json[currency.toLowerCase()] as Map<String, dynamic>?;
      final kes = (rates?['kes'] as num?)?.toDouble();
      return kes != null && kes > 0 ? kes : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<double?> toKes(String currency, DateTime day) async {
    if (currency.toUpperCase() == 'KES') return 1;
    final key = '${currency.toUpperCase()} ${_ymd(day)}';
    if (_cache[key] case final cached?) return cached;
    for (final url in urls(currency, day, DateTime.now())) {
      final client = _client()..connectionTimeout = const Duration(seconds: 8);
      try {
        final request = await client.getUrl(url);
        final response = await request.close().timeout(
          const Duration(seconds: 10),
        );
        if (response.statusCode != 200) {
          await response.drain<void>();
          continue;
        }
        final body = await response.transform(utf8.decoder).join();
        if (parse(currency, body) case final rate?) {
          return _cache[key] = rate;
        }
      } catch (_) {
        // Offline or blocked: try the next source.
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }
}
