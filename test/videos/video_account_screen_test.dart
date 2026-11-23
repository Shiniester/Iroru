import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/providers/audio_provider.dart';
import 'package:iroru/src/videos/missav_client.dart';
import 'package:iroru/src/videos/missav_verification.dart';
import 'package:iroru/src/videos/ui/video_account_screen.dart';
import 'package:iroru/src/videos/video_models.dart';
import 'package:iroru/src/videos/video_providers.dart';

typedef _MissavAccountLogin =
    Future<bool> Function(BuildContext context, MissavClient client);
typedef _MissavAccountVerifier =
    Future<MissavVerificationResult> Function(
      BuildContext context,
      MissavClient client, {
      required String sourceUrl,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('opens the web account login flow', (tester) async {
    final client = _TestMissavClient();
    var loginCalls = 0;
    final firstLogin = Completer<bool>();
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        login: (_, _) async {
          loginCalls++;
          if (loginCalls == 1) return firstLogin.future;
          client.confirmAccount('web-viewer');
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(client.restoreAccountCalls, 0);
    expect(client.browserAccessChecks, 0);
    expect(find.byType(TextField), findsNothing);
    expect(find.text(s.videoVerifyAccess), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);

    await tester.tap(find.text(s.login));
    await tester.pump();
    expect(loginCalls, 1);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, s.login))
          .onPressed,
      isNull,
    );

    firstLogin.complete(false);
    await tester.pumpAndSettle();
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.login), findsOneWidget);

    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(loginCalls, 2);
    expect(find.text('web-viewer'), findsOneWidget);
    expect(find.text(s.logout), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  testWidgets('restores a saved sign-in and clears it on logout', (
    tester,
  ) async {
    final restore = Completer<bool>();
    final client = _TestMissavClient(restoredAccountName: 'saved-viewer')
      ..restoreAccountCompleter = restore;
    var cleanupCalls = 0;
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      _app(client, clearBrowserSession: () async => cleanupCalls++),
    );
    await tester.pump();

    expect(client.restoreAccountCalls, 1);
    expect(find.text(s.videoAccountRestoring), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(s.login), findsNothing);

    restore.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('saved-viewer'), findsOneWidget);
    expect(client.browserAccessChecks, 0);

    await tester.tap(find.text(s.logout));
    await tester.pumpAndSettle();
    expect(client.logoutCalls, 1);
    expect(cleanupCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.login), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('transient restore failure keeps the session and retries', (
    tester,
  ) async {
    final client = _TestMissavClient(restoredAccountName: 'saved-viewer')
      ..restoreAccountError = const MissavException('Restore failed.');
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(find.text(s.videoAccountRestoreFailed), findsOneWidget);
    expect(find.text(s.login), findsOneWidget);
    expect(find.text(s.videoLoginRequired), findsNothing);
    expect(find.text(s.videoVerifyAccess), findsNothing);
    expect(find.text(s.retry), findsOneWidget);
    expect(client.hasRestorableSession, isTrue);

    client.restoreAccountError = null;
    await tester.tap(find.text(s.retry));
    await tester.pumpAndSettle();

    expect(client.restoreAccountCalls, 2);
    expect(find.text('saved-viewer'), findsOneWidget);
  });

  testWidgets('can start and cancel web login after restoration times out', (
    tester,
  ) async {
    final client = _TestMissavClient(savedSession: true)
      ..restoreAccountError = TimeoutException('Restore timed out.');
    final s = await S.delegate.load(const Locale('en'));
    var loginCalls = 0;
    await tester.pumpWidget(
      _app(
        client,
        login: (_, _) async {
          loginCalls++;
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(s.login), findsOneWidget);
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(loginCalls, 1);
    expect(client.hasRestorableSession, isTrue);
    expect(find.text(s.login), findsOneWidget);
    expect(find.text(s.retry), findsOneWidget);
  });

  testWidgets('verification keeps a confirmed account signed in', (
    tester,
  ) async {
    final client = _TestMissavClient(savedSession: true)
      ..confirmAccount('previous-viewer')
      ..restoreAccountError = const MissavVerificationRequiredException(
        sourceUrl: 'https://missav.ai/en/api/login',
      );
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(client.isLoggedIn, isTrue);
    expect(find.text(s.videoVerificationRequired), findsOneWidget);
    expect(find.text('previous-viewer'), findsOneWidget);
    expect(find.text(s.login), findsOneWidget);
    expect(find.text(s.videoVerifyAccess), findsOneWidget);
    expect(find.text(s.retry), findsOneWidget);
    await tester.ensureVisible(find.text(s.logout));
    await tester.tap(find.text(s.logout));
    await tester.pumpAndSettle();

    expect(client.logoutCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.videoVerificationRequired), findsNothing);
    expect(find.text(s.retry), findsNothing);
  });

  for (final previouslySignedIn in [false, true]) {
    testWidgets(
      'invalid saved session shows web login (signed in: $previouslySignedIn)',
      (tester) async {
        final client = _TestMissavClient(savedSession: true);
        if (previouslySignedIn) client.confirmAccount('previous-viewer');
        final s = await S.delegate.load(const Locale('en'));
        await tester.pumpWidget(_app(client));
        await tester.pumpAndSettle();

        expect(client.restoreAccountCalls, 1);
        expect(client.isLoggedIn, isFalse);
        expect(client.hasRestorableSession, isFalse);
        expect(find.text(s.videoAccountRestoring), findsNothing);
        expect(find.text(s.login), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
      },
    );
  }

  testWidgets('stale restore result keeps an externally confirmed account', (
    tester,
  ) async {
    final restore = Completer<bool>();
    final client = _TestMissavClient(restoredAccountName: 'saved-viewer')
      ..restoreAccountCompleter = restore;
    await tester.pumpWidget(_app(client));
    await tester.pump();

    client.confirmAccount('external-viewer');
    await tester.pump();
    expect(find.text('external-viewer'), findsOneWidget);

    restore.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('external-viewer'), findsOneWidget);
  });

  for (final fromDetails in [false, true]) {
    testWidgets('recovers a blocked saved account (details: $fromDetails)', (
      tester,
    ) async {
      const challengeUrl = 'https://missav.ai/en/api/login';
      const challenge = MissavVerificationRequiredException(
        sourceUrl: challengeUrl,
      );
      final client = _TestMissavClient(savedSession: true)
        ..restoreAccountError = challenge;
      final requests = <String>[];
      final verification = Completer<MissavVerificationResult>();
      final s = await S.delegate.load(const Locale('en'));

      await tester.pumpWidget(
        _app(
          client,
          restoreError: fromDetails ? challenge : null,
          verifier: (_, _, {required sourceUrl}) async {
            requests.add(sourceUrl);
            client.restoredAccountName = 'web-viewer';
            return verification.future;
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(s.videoVerificationRequired), findsOneWidget);
      expect(find.text(s.login), findsOneWidget);
      await tester.tap(find.text(s.videoVerifyAccess));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, s.retry))
            .onPressed,
        isNull,
      );

      verification.complete((verified: true, signedIn: false));
      await tester.pumpAndSettle();
      expect(requests, [challengeUrl]);
      expect(client.restoreAccountCalls, fromDetails ? 0 : 1);
      expect(client.browserAccessChecks, 1);
      expect(find.text('web-viewer'), findsOneWidget);
    });
  }

  testWidgets('access denial offers the approved source without verifying', (
    tester,
  ) async {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launchedUrls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'launch') return null;
      launchedUrls.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final client = _TestMissavClient(savedSession: true)
      ..restoreAccountError = const MissavAccessDeniedException(
        sourceUrl: 'https://unapproved.example.test/en/api/login',
      );
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(_app(client));
    await tester.pumpAndSettle();

    expect(find.text(s.videoAccessDenied), findsOneWidget);
    expect(find.text(s.videoVerifyAccess), findsNothing);
    await tester.tap(find.text(s.videoOpenSource));
    await tester.pumpAndSettle();
    expect(launchedUrls, [client.originHomeUrl]);
  });

  for (final hasRetryTime in [false, true]) {
    testWidgets('rate limiting tells when to retry (time: $hasRetryTime)', (
      tester,
    ) async {
      final retryAt = hasRetryTime
          ? DateTime.now().toUtc().add(const Duration(hours: 2))
          : null;
      final client = _TestMissavClient(savedSession: true)
        ..restoreAccountError = MissavRateLimitException(
          sourceUrl: 'https://missav.ai/en',
          retryAt: retryAt,
        );
      final s = await S.delegate.load(const Locale('en'));
      await tester.pumpWidget(_app(client));
      await tester.pumpAndSettle();

      final message = retryAt == null
          ? s.videoRateLimited
          : s.videoRateLimitedUntil(
              DateFormat.yMMMd(s.localeName).add_jm().format(retryAt.toLocal()),
            );
      expect(find.text(message), findsOneWidget);
      expect(find.text(s.login), findsOneWidget);
      expect(find.text(s.retry), findsOneWidget);
    });
  }
}

Widget _app(
  _TestMissavClient client, {
  _MissavAccountLogin? login,
  _MissavAccountVerifier? verifier,
  Future<void> Function()? clearBrowserSession,
  Object? restoreError,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    if (login != null) missavAccountLoginProvider.overrideWithValue(login),
    if (verifier != null)
      missavAccountVerifierProvider.overrideWithValue(verifier),
    videoBrowserSessionCleanupProvider.overrideWithValue(
      clearBrowserSession ?? () async {},
    ),
    currentTrackProvider.overrideWith((ref) => Stream.value(null)),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    supportedLocales: S.supportedLocales,
    localizationsDelegates: S.localizationsDelegates,
    theme: ThemeData(useMaterial3: true),
    home: VideoAccountScreen(restoreError: restoreError),
  ),
);

class _TestMissavClient extends MissavClient {
  _TestMissavClient({this.restoredAccountName, bool? savedSession})
    : savedSession = savedSession ?? restoredAccountName != null,
      super(secureStorage: _TestSecureStorage());

  String? restoredAccountName;
  bool savedSession;
  bool _loggedIn = false;
  String? _name;
  int restoreAccountCalls = 0;
  int browserAccessChecks = 0;
  int logoutCalls = 0;
  Object? restoreAccountError;
  Completer<bool>? restoreAccountCompleter;

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  bool get hasRestorableSession => savedSession;

  @override
  String? get accountName => _name;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> restoreAccount({bool recheck = false}) async {
    restoreAccountCalls++;
    if (restoreAccountError case final error?) throw error;
    final previousName = _name;
    final restored =
        await restoreAccountCompleter?.future ?? restoredAccountName != null;
    if (previousName != _name) return false;
    if (restoredAccountName case final String name when restored) {
      confirmAccount(name);
      return true;
    }
    savedSession = false;
    _loggedIn = false;
    _name = null;
    return false;
  }

  @override
  Future<void> checkBrowserAccess({
    Map<String, dynamic>? browserUser,
    CancelToken? cancelToken,
  }) async {
    browserAccessChecks++;
    if (cancelToken?.cancelError case final error?) throw error;
    if (restoredAccountName case final name?) confirmAccount(name);
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    savedSession = false;
    _loggedIn = false;
    _name = null;
    notifyListeners();
  }

  @override
  Future<void> login({required String email, required String password}) async {
    fail('The account screen must use web login.');
  }

  void confirmAccount(String name) {
    savedSession = true;
    _loggedIn = true;
    _name = name;
    notifyListeners();
  }
}

class _TestSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
