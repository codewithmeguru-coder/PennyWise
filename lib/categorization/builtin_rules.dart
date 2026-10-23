/// Built-in knowledge used by `CategorySuggester`, separate from the code
/// so it is easy to review and extend. Category ids are the ones in
/// `DefaultCategories`.
///
/// * [knownNames]: specific businesses whose purpose is clear from the name
///   alone. A match is **high** confidence.
/// * [keywords]: words that usually, but not always, say what a payment
///   was for. A match is **medium** confidence.
///
/// Matching is on whole words of the normalised name; when several entries
/// match, the longest phrase wins (e.g. "KENYA POWER" beats "POWER").
class BuiltinRules {
  BuiltinRules._();

  static const Map<String, String> knownNames = {
    // Airtime & data
    'SAFARICOM OFFERS': 'airtime_data',
    'SAFARICOM DATA BUNDLES': 'airtime_data',
    'TUNUKIWA': 'airtime_data',
    'OKOA JAHAZI': 'airtime_data',
    // Utilities
    'KPLC PREPAID': 'bills',
    'KPLC POSTPAID': 'bills',
    'KENYA POWER': 'bills',
    'NAIROBI CITY WATER': 'bills',
    'NCWSC': 'bills',
    'ZUKU': 'bills',
    'SAFARICOM HOME': 'bills',
    // Subscriptions
    'NETFLIX': 'subscriptions',
    'SHOWMAX': 'subscriptions',
    'SPOTIFY': 'subscriptions',
    'DSTV': 'subscriptions',
    'GOTV': 'subscriptions',
    'STARTIMES': 'subscriptions',
    'YOUTUBE PREMIUM': 'subscriptions',
    // Shopping (supermarkets, online shops)
    'NAIVAS': 'shopping',
    'QUICKMART': 'shopping',
    'QUICK MART': 'shopping',
    'CARREFOUR': 'shopping',
    'CHANDARANA': 'shopping',
    'CLEANSHELF': 'shopping',
    'MAGUNAS': 'shopping',
    'JUMIA': 'shopping',
    'KILIMALL': 'shopping',
    // Transport
    'UBER': 'transport',
    'BOLT': 'transport',
    'LITTLE CAB': 'transport',
    'NTSA': 'transport',
    // Food
    'KFC': 'food',
    'JAVA HOUSE': 'food',
    'ARTCAFFE': 'food',
    'GLOVO': 'food',
    'PIZZA INN': 'food',
    'CHICKEN INN': 'food',
    // Healthcare
    'NHIF': 'health',
    'SOCIAL HEALTH AUTHORITY': 'health',
    // Education
    'HELB': 'education',
  };

  static const Map<String, String> keywords = {
    'AIRTIME': 'airtime_data',
    'BUNDLE': 'airtime_data',
    'BUNDLES': 'airtime_data',
    'SCHOOL': 'education',
    'ACADEMY': 'education',
    'UNIVERSITY': 'education',
    'COLLEGE': 'education',
    'TUITION': 'education',
    'FEES': 'education',
    'RENT': 'housing',
    'LANDLORD': 'housing',
    'APARTMENTS': 'housing',
    'APARTMENT': 'housing',
    'MATATU': 'transport',
    'SACCO': 'transport',
    'FUEL': 'transport',
    'PETROL': 'transport',
    'SERVICE STATION': 'transport',
    'PARKING': 'transport',
    'SHELL': 'transport',
    'RUBIS': 'transport',
    'TOTALENERGIES': 'transport',
    'RESTAURANT': 'food',
    'CAFE': 'food',
    'EATERY': 'food',
    'BUTCHERY': 'food',
    'BAKERY': 'food',
    'KITCHEN': 'food',
    'HOTEL': 'food',
    'SUPERMARKET': 'shopping',
    'MINIMART': 'shopping',
    'SHOP': 'shopping',
    'STORES': 'shopping',
    'MART': 'shopping',
    'PREPAID': 'bills',
    'POSTPAID': 'bills',
    'WATER': 'bills',
    'INTERNET': 'bills',
    'FIBRE': 'bills',
    'FIBER': 'bills',
    'HOSPITAL': 'health',
    'PHARMACY': 'health',
    'CHEMIST': 'health',
    'CLINIC': 'health',
    'MEDICAL': 'health',
    'DENTAL': 'health',
    'CINEMA': 'entertainment',
    'IMAX': 'entertainment',
    'SALON': 'personal_care',
    'BARBER': 'personal_care',
    'BARBERSHOP': 'personal_care',
    'BEAUTY': 'personal_care',
    'SPA': 'personal_care',
    'COSMETICS': 'personal_care',
  };

  /// Received-money names or texts that point to salary.
  static const salaryWords = ['SALARY', 'PAYROLL', 'WAGES', 'STIPEND'];

  /// Words that mark a bank's Paybill: the message says money went to a
  /// bank, not what it was for, so these always go to review.
  static const bankWords = [
    'BANK', 'C2B', 'PAYBILL ACCOUNT', 'BULK ACCOUNT', 'EQUITY', 'KCB',
    'CO OP', 'COOP', 'NCBA', 'ABSA', 'STANBIC', 'DTB', 'FAMILY BANK',
  ];
}
