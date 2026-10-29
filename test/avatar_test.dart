import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:pennywise/data/data_exception.dart';
import 'package:pennywise/models/avatar_photo.dart';
import 'package:pennywise/services/auth_service.dart';
import 'package:pennywise/services/avatar_store.dart';
import 'package:pennywise/services/photo_picker.dart';
import 'package:pennywise/widgets/user_avatar.dart';

import 'fake_auth_service.dart';
import 'fake_avatar.dart';
import 'test_app.dart';

// Profile photo: format and size checks (the same as the Firestore rules),
// the Android picker's settings, saving / removing / recovering, the
// fallback to the Google photo or initials, and that one profile's photo
// never shows for another. In memory only.

/// A real 1×1 PNG, so it can actually be drawn.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
Uint8List jpeg([int size = 2000]) =>
    Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(size - 4, 7)]);
final webp = Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0,
  0,
  0,
  0,
  ...'WEBP'.codeUnits,
  ...List.filled(50, 2),
]);
final gif = Uint8List.fromList([...'GIF89a'.codeUnits, ...List.filled(50, 3)]);

/// A real 1×1 lossless WebP, and RIFF files that are not WebP.
final realWebp = base64Decode(
  'UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==',
);
Uint8List riff(String kind) => Uint8List.fromList([
  ...'RIFF'.codeUnits,
  0x24,
  0,
  0,
  0,
  ...kind.codeUnits,
  ...List.filled(50, 5),
]);
final heic = Uint8List.fromList([
  0,
  0,
  0,
  24,
  ...'ftypheic'.codeUnits,
  ...List.filled(50, 4),
]);

/// Records what the Android picker is asked for.
class RecordingPlatform extends ImagePickerPlatform {
  ImageSource? source;
  ImagePickerOptions? options;
  XFile? result;
  PlatformException? error;
  LostDataResponse lost = LostDataResponse.empty();

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    this.source = source;
    this.options = options;
    if (error case final e?) throw e;
    return result;
  }

  @override
  Future<LostDataResponse> getLostData() async => lost;
}

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('photo checks (same as the rules)', () {
    test('JPEG, PNG and WebP are recognised; others are not', () {
      expect(AvatarPhoto.formatOf(jpeg()), PhotoFormat.jpeg);
      expect(AvatarPhoto.formatOf(png), PhotoFormat.png);
      expect(AvatarPhoto.formatOf(webp), PhotoFormat.webp);
      expect(AvatarPhoto.formatOf(gif), isNull);
      expect(AvatarPhoto.formatOf(realWebp), PhotoFormat.webp);
      expect(AvatarPhoto.formatOf(riff('WAVEfmt ')), isNull);
      expect(AvatarPhoto.formatOf(riff('AVI LIST')), isNull);
      expect(AvatarPhoto.formatOf(heic), isNull);
      expect(AvatarPhoto.formatOf(Uint8List(0)), isNull);
    });

    test('up to 250 KB is accepted; more is not', () {
      expect(AvatarPhoto.problemWith(jpeg(250 * 1024)), isNull);
      expect(
        AvatarPhoto.problemWith(jpeg(250 * 1024 + 1)),
        contains('too large'),
      );
      expect(AvatarPhoto.problemWith(gif), 'Choose a JPEG, PNG or WebP photo.');
      expect(
        AvatarPhoto.problemWith(Uint8List(0)),
        contains('couldn\'t be read'),
      );
    });

    test('the largest photo fits the rules\' base64 limit exactly', () {
      expect(
        AvatarPhoto.encode(jpeg(250 * 1024)).length,
        AvatarPhoto.maxBase64Length,
      );
      expect(AvatarPhoto.maxBase64Length, 341336); // as in firestore.rules
      expect(AvatarPhoto.encode(jpeg()), startsWith('/9j/'));
      expect(AvatarPhoto.encode(png), startsWith('iVBORw0KGgo'));
      // The same patterns as firestore.rules.
      final rule = RegExp(
        r'^(/9j/|iVBORw0KGgo|UklGR[A-Za-z0-9+/]{6}XRUJQ)'
        r'[A-Za-z0-9+/]*={0,2}$',
      );
      expect(rule.hasMatch(AvatarPhoto.encode(webp)), isTrue);
      expect(rule.hasMatch(AvatarPhoto.encode(realWebp)), isTrue);
      expect(rule.hasMatch(AvatarPhoto.encode(png)), isTrue);
      expect(rule.hasMatch(AvatarPhoto.encode(jpeg())), isTrue);
      expect(rule.hasMatch(AvatarPhoto.encode(riff('WAVEfmt '))), isFalse);
      expect(rule.hasMatch(AvatarPhoto.encode(riff('AVI LIST'))), isFalse);
    });

    test('stored text is read back only if it is a photo', () {
      expect(AvatarPhoto.decode(AvatarPhoto.encode(png)), png);
      expect(AvatarPhoto.decode('not base64!'), isNull);
      expect(AvatarPhoto.decode(base64Encode(gif)), isNull);
      expect(AvatarPhoto.decode(null), isNull);
      expect(AvatarPhoto.decode(5), isNull);
    });
  });

  group('Android picker', () {
    test('gallery only, 256 × 256, quality 80, no extra metadata', () async {
      final platform = RecordingPlatform()
        ..result = XFile.fromData(png, name: 'p.png');
      final bytes = await AndroidPhotoPicker(platform: platform).pick();
      expect(bytes, png);
      expect(platform.source, ImageSource.gallery);
      expect(platform.options!.maxWidth, 256);
      expect(platform.options!.maxHeight, 256);
      expect(platform.options!.imageQuality, 80);
      expect(platform.options!.requestFullMetadata, isFalse);
    });

    test('the system Photo Picker is turned on (Android 12 and below too)', () {
      final android = ImagePickerAndroid();
      expect(android.useAndroidPhotoPicker, isFalse);
      AndroidPhotoPicker(platform: android);
      expect(android.useAndroidPhotoPicker, isTrue);
    });

    test(
      'cancel gives null; a picker failure gives a friendly error',
      () async {
        final platform = RecordingPlatform();
        expect(await AndroidPhotoPicker(platform: platform).pick(), isNull);
        platform.error = PlatformException(code: 'photo_access_denied');
        expect(
          () => AndroidPhotoPicker(platform: platform).pick(),
          throwsA(
            isA<PhotoPickerException>().having(
              (e) => e.message,
              'message',
              contains('Couldn\'t open your photos'),
            ),
          ),
        );
      },
    );

    test('lost data: none, a photo, or an error', () async {
      final platform = RecordingPlatform();
      final picker = AndroidPhotoPicker(platform: platform);
      expect(await picker.recoverLost(), isNull);
      platform.lost = LostDataResponse(file: XFile.fromData(png));
      expect(await picker.recoverLost(), png);
      platform.lost = LostDataResponse(exception: PlatformException(code: 'x'));
      expect(picker.recoverLost(), throwsA(isA<PhotoPickerException>()));
    });
  });

  group('AvatarStore', () {
    test('a picked photo is saved; cancelling saves nothing', () async {
      final repo = FakeAvatarRepository();
      final store = AvatarStore(repo);
      final picker = FakePhotoPicker();
      expect(await store.change(picker), isNull); // cancelled
      expect(repo.writes, isEmpty);
      picker.next = png;
      expect(await store.change(picker), isNull);
      await settle();
      expect(repo.writes, ['save ${png.length}']);
      expect(store.photo, png);
      store.dispose();
    });

    test('too large or the wrong format: a message, nothing saved', () async {
      final repo = FakeAvatarRepository();
      final store = AvatarStore(repo);
      final picker = FakePhotoPicker()..next = jpeg(300 * 1024);
      expect(await store.change(picker), contains('too large'));
      picker.next = heic;
      expect(await store.change(picker), 'Choose a JPEG, PNG or WebP photo.');
      expect(repo.writes, isEmpty);
      store.dispose();
    });

    test('a failed save says why and keeps the old photo', () async {
      final repo = FakeAvatarRepository(png)
        ..writeError = const DataException('No connection.');
      final store = AvatarStore(repo);
      await settle();
      final picker = FakePhotoPicker()..next = jpeg();
      expect(await store.change(picker), 'No connection.');
      await settle();
      expect(store.photo, png);
      expect(store.isBusy, isFalse);
      store.dispose();
    });

    test('a picker failure says why', () async {
      final store = AvatarStore(FakeAvatarRepository());
      final picker = FakePhotoPicker()
        ..error = const PhotoPickerException('Couldn\'t open your photos.');
      expect(await store.change(picker), 'Couldn\'t open your photos.');
      store.dispose();
    });

    test('remove clears it', () async {
      final repo = FakeAvatarRepository(png);
      final store = AvatarStore(repo);
      await settle();
      expect(await store.remove(), isNull);
      await settle();
      expect(store.photo, isNull);
      expect(repo.writes, ['remove']);
      store.dispose();
    });

    test('a load error leaves no photo (Google or initials show)', () async {
      final repo = FakeAvatarRepository(png)
        ..loadError = const DataException('No connection.');
      final store = AvatarStore(repo);
      await settle();
      expect(store.photo, isNull);
      expect(store.error, 'No connection.');
      store.dispose();
    });

    test('a photo lost when Android closed the app is saved', () async {
      final repo = FakeAvatarRepository();
      final store = AvatarStore(repo);
      final picker = FakePhotoPicker()..lost = png;
      expect(await store.recover(picker), isNull);
      expect(repo.writes, ['save ${png.length}']);
      expect(await store.recover(picker), isNull); // nothing more
      expect(repo.writes, hasLength(1));
      store.dispose();
    });
  });

  group('UserAvatar fallback', () {
    const google = AppUser(
      uid: 'g',
      email: 'ann@gmail.com',
      displayName: 'Ann',
      photoUrl: 'https://example.com/ann.jpg',
    );
    const plain = AppUser(uid: 'e', email: 'bob@example.com');

    CircleAvatar circle(WidgetTester tester) =>
        tester.widget<CircleAvatar>(find.byType(CircleAvatar));

    Future<void> show(WidgetTester tester, Widget avatar) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: avatar)),
      ),
    );

    testWidgets('own photo first', (tester) async {
      await show(tester, UserAvatar(user: google, customImage: png));
      expect(circle(tester).foregroundImage, isA<MemoryImage>());
    });

    testWidgets('then the Google photo', (tester) async {
      await show(tester, const UserAvatar(user: google));
      expect(circle(tester).foregroundImage, isA<NetworkImage>());
      expect(circle(tester).onForegroundImageError, isNotNull);
    });

    testWidgets('then the initial', (tester) async {
      await show(tester, const UserAvatar(user: plain));
      expect(circle(tester).foregroundImage, isNull);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets('a photo that can\'t be drawn leaves the initial visible', (
      tester,
    ) async {
      await show(tester, UserAvatar(user: plain, customImage: jpeg()));
      await tester.pumpAndSettle();
      expect(circle(tester).onForegroundImageError, isNotNull);
      expect(find.text('B'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Settings › Profile', () {
    Future<void> openSettings(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Settings').first);
      await tester.pumpAndSettle();
    }

    /// The avatar in the side menu's header (the menu is opened first).
    Future<CircleAvatar> menuAvatar(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Menu').first);
      await tester.pumpAndSettle();
      final avatar = tester.widget<CircleAvatar>(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.byType(CircleAvatar),
        ),
      );
      Navigator.of(tester.element(find.byType(Drawer))).pop();
      await tester.pumpAndSettle();
      return avatar;
    }

    testWidgets(
      'add, then remove (after confirming); the menu header follows',
      (tester) async {
        final repo = FakeAvatarRepository();
        final picker = FakePhotoPicker()..next = png;
        await pumpApp(tester, avatars: (_) => repo, photoPicker: picker);
        await openSettings(tester);
        expect(find.text('Add photo'), findsOneWidget);
        expect(find.text('Remove photo'), findsNothing);

        await tester.tap(find.text('Add photo'));
        await tester.pumpAndSettle();
        expect(repo.photo, png);
        expect(find.text('Change photo'), findsOneWidget);
        // The settings card shows it, and so does the menu header.
        expect(
          tester
              .widget<CircleAvatar>(find.byType(CircleAvatar))
              .foregroundImage,
          isA<MemoryImage>(),
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect((await menuAvatar(tester)).foregroundImage, isA<MemoryImage>());
        await openSettings(tester);

        await tester.tap(find.text('Remove photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(repo.photo, png);

        await tester.tap(find.text('Remove photo'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Remove'));
        await tester.pumpAndSettle();
        expect(repo.photo, isNull);
        expect(find.text('Add photo'), findsOneWidget);
        // The menu header falls back too.
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect((await menuAvatar(tester)).foregroundImage, isNull);
      },
    );

    testWidgets('problems show as messages, and nothing changes', (
      tester,
    ) async {
      final repo = FakeAvatarRepository();
      final picker = FakePhotoPicker()..next = gif;
      await pumpApp(tester, avatars: (_) => repo, photoPicker: picker);
      await openSettings(tester);
      await tester.tap(find.text('Add photo'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a JPEG, PNG or WebP photo.'), findsOneWidget);

      picker.next = png;
      repo.writeError = const DataException('No connection.');
      await tester.tap(find.text('Add photo'));
      await tester.pumpAndSettle();
      expect(find.text('No connection.'), findsOneWidget);
      expect(repo.photo, isNull);
    });

    testWidgets('a photo lost while the picker was open is saved when '
        'Settings opens', (tester) async {
      final repo = FakeAvatarRepository();
      final picker = FakePhotoPicker()..lost = png;
      await pumpApp(tester, avatars: (_) => repo, photoPicker: picker);
      await openSettings(tester);
      expect(repo.photo, png);
      expect(find.text('Change photo'), findsOneWidget);
    });

    testWidgets('one profile\'s photo never shows for another', (tester) async {
      final repos = <String, FakeAvatarRepository>{
        FakeAuthService.testUser.uid: FakeAvatarRepository(png),
      };
      final auth = FakeAuthService(signedInAs: FakeAuthService.testUser);
      await pumpApp(
        tester,
        auth: auth,
        avatars: (uid) => repos.putIfAbsent(uid, FakeAvatarRepository.new),
      );
      await tester.pumpAndSettle();
      await openSettings(tester);
      expect(find.text('Change photo'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await auth.signOut();
      await tester.pumpAndSettle();
      await auth.signIn(email: 'bea@example.com', password: 'secret12');
      await tester.pumpAndSettle();
      await openSettings(tester);
      expect(find.text('Add photo'), findsOneWidget);
      expect(find.text('Change photo'), findsNothing);
      expect(repos['u-bea@example.com']!.photo, isNull);
    });
  });
}
