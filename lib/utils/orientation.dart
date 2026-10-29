import 'package:flutter/services.dart';

/// PennyWise is laid out for a phone held upright. This asks Android to
/// keep *this app's* screen in portrait; it never reads or changes the
/// phone's own auto-rotate setting (the app has no permission to), and
/// other apps rotate as before.
Future<void> lockAppToPortrait() =>
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
