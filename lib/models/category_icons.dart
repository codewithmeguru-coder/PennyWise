import 'package:flutter/material.dart';

/// The icons a custom category can use, stored by key (e.g. "pets").
///
/// A fixed list of constants, not raw icon codes: release builds keep only
/// the icons the code names, so an icon stored as a number could vanish.
class CategoryIcons {
  CategoryIcons._();

  static const fallback = 'label';

  static const Map<String, IconData> all = {
    'label': Icons.label_rounded,
    'pets': Icons.pets_rounded,
    'church': Icons.church_rounded,
    'sports': Icons.sports_soccer_rounded,
    'fitness': Icons.fitness_center_rounded,
    'travel': Icons.flight_rounded,
    'car': Icons.directions_car_rounded,
    'fuel': Icons.local_gas_station_rounded,
    'home': Icons.home_rounded,
    'tools': Icons.build_rounded,
    'child': Icons.child_care_rounded,
    'school': Icons.school_rounded,
    'gift': Icons.card_giftcard_rounded,
    'coffee': Icons.local_cafe_rounded,
    'restaurant': Icons.restaurant_rounded,
    'groceries': Icons.local_grocery_store_rounded,
    'clothes': Icons.checkroom_rounded,
    'beauty': Icons.face_retouching_natural_rounded,
    'medical': Icons.medical_services_rounded,
    'phone': Icons.smartphone_rounded,
    'internet': Icons.wifi_rounded,
    'music': Icons.music_note_rounded,
    'game': Icons.sports_esports_rounded,
    'charity': Icons.volunteer_activism_rounded,
    'work': Icons.work_rounded,
    'farm': Icons.agriculture_rounded,
    'money': Icons.payments_rounded,
    'shop': Icons.storefront_rounded,
  };

  /// The icon for [key]; the fallback for an unknown key.
  static IconData of(String key) => all[key] ?? all[fallback]!;
}
