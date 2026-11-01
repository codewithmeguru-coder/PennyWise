import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';
import 'security/app_check_setup.dart';
import 'utils/orientation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Portrait for this app only; the phone's auto-rotate is left alone.
  await lockAppToPortrait();

  // Must finish before any Firebase service (e.g. Auth) is used.
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // App Check before Auth or Firestore send their first request (Play
  // Integrity in release builds; the debug provider only in debug builds).
  await AppCheckSetup.activate();

  runApp(const PennyWiseApp());
}
