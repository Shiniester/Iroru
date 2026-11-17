import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/missav_verification.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_account_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';

typedef _MissavAccountVerifier =
    Future<MissavVerificationResult> Function(
      BuildContext context,
      MissavClient client, {
      required String sourceUrl,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('refreshes a saved sign-in before showing the account state', (
    tester,
  ) async {
    final client = _TestMissavClient(restoredAccountName: 'saved-viewer');
    var cleanupCalls = 0;
    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async =>
            (verified: false, signedIn: false),
        clearBrowserSession: () async => cleanupCalls++,
      ),
    );
    await tester.pumpAndSettle();

    expect(client.browserAccessChecks, 1);
    expect(find.text('saved-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    final s = await S.delegate.load(const Locale('en'));
    await tester.tap(find.text(s.logout));
    await tester.pumpAndSettle();

    expect(client.logoutCalls, 1);
    expect(cleanupCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.login), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('verification button accepts a manual web sign-in', (
    tester,
  ) async {
    final client = _TestMissavClient();
    final requests = <({String sourceUrl})>[];
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          requests.add((sourceUrl: sourceUrl));
          client.confirmAccount('web-viewer');
          return (verified: true, signedIn: true);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();
    expect(requests.last, (sourceUrl: 'https://missav.ai/cn'));
    expect(client.nativeLoginCalls, 0);
    expect(find.text('web-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('native login succeeds without opening the browser', (
    tester,
  ) async {
    final client = _TestMissavClient();
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: true, signedIn: true);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'viewer@example.test');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 1);
    expect(verifierCalls, 0);
    expect(find.text('native-viewer'), findsOneWidget);
  });

  testWidgets('blocked login waits for a tap before verifying and retrying', (
    tester,
  ) async {
    const challengeUrl = 'https://missav.ai/en/api/login';
    final client = _TestMissavClient()..nativeLoginChallengeUrl = challengeUrl;
    final requests = <({String sourceUrl})>[];
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          requests.add((sourceUrl: sourceUrl));
          client.nativeLoginChallengeUrl = null;
          return (verified: true, signedIn: false);
        },
      ),
    );
    await tester.pumpAndSettle();

    await _submitLogin(tester, s);

    expect(requests, isEmpty);
    expect(client.nativeLogins, [_credentials]);
    expect(find.text(s.videoVerificationRequired), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(requests, [(sourceUrl: challengeUrl)]);
    expect(client.nativeLogins, [_credentials, _credentials]);
    expect(find.text(s.videoVerificationRequired), findsNothing);
    expect(find.text('native-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  for (final signedInOnWeb in [true, false]) {
    testWidgets(
      signedInOnWeb
          ? 'keeps the web sign-in without resubmitting the password'
          : 'a rejected retry after verification shows a login error',
      (tester) async {
        final client = _TestMissavClient()
          ..nativeLoginChallengeUrl = 'https://missav.ai/en/api/login';
        final s = await S.delegate.load(const Locale('en'));
        await tester.pumpWidget(
          _app(
            client,
            verifier: (_, _, {required sourceUrl}) async {
              client.nativeLoginChallengeUrl = null;
              client.rejectLogin = true;
              if (signedInOnWeb) client.confirmAccount('web-viewer');
              return (verified: true, signedIn: signedInOnWeb);
            },
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byType(TextField).first,
          'viewer@example.test',
        );
        await tester.enterText(find.byType(TextField).last, 'password');
        await tester.tap(find.text(s.login));
        await tester.pumpAndSettle();
        await tester.tap(find.text(s.videoVerifyAccess));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(client.nativeLoginCalls, signedInOnWeb ? 1 : 2);
        expect(client.isLoggedIn, signedInOnWeb);
        if (signedInOnWeb) {
          expect(find.text('web-viewer'), findsOneWidget);
          expect(find.byType(TextField), findsNothing);
        } else {
          expect(find.text(s.loginFailed), findsOneWidget);
          expect(find.widgetWithText(FilledButton, s.login), findsOneWidget);
        }
      },
    );
  }

  for (final editForm in [false, true]) {
    testWidgets(
      editForm
          ? 'verification does not submit edited credentials'
          : 'manual verification does not submit a filled form',
      (tester) async {
        final client = _TestMissavClient();
        final s = await S.delegate.load(const Locale('en'));
        await tester.pumpWidget(
          _app(
            client,
            verifier: (_, _, {required sourceUrl}) async =>
                (verified: true, signedIn: false),
          ),
        );
        await tester.pumpAndSettle();

        if (editForm) {
          client.nativeLoginChallengeUrl = 'https://missav.ai/en';
          await _submitLogin(tester, s);
        } else {
          await tester.enterText(
            find.byType(TextField).first,
            _credentials.email,
          );
        }
        await tester.enterText(find.byType(TextField).last, 'new-password');
        await tester.tap(find.text(s.videoVerifyAccess));
        await tester.pumpAndSettle();

        expect(client.nativeLoginCalls, editForm ? 1 : 0);
        expect(find.text(s.videoVerificationRequired), findsNothing);
        expect(find.byType(TextField), findsNWidgets(2));
      },
    );
  }

  testWidgets('another challenge does not rearm the blocked login', (
    tester,
  ) async {
    final client = _TestMissavClient()
      ..nativeLoginChallengeUrl = 'https://missav.ai/en';
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: true, signedIn: false);
        },
      ),
    );
    await tester.pumpAndSettle();

    await _submitLogin(tester, s);
    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 2);
    expect(verifierCalls, 1);
    expect(find.text(s.videoOpenSource), findsOneWidget);

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(verifierCalls, 2);
    expect(client.nativeLoginCalls, 2);
  });

  testWidgets('cancelled verification keeps the login form retryable', (
    tester,
  ) async {
    final client = _TestMissavClient()
      ..nativeLoginChallengeUrl = 'https://missav.ai/en';
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: false, signedIn: false);
        },
      ),
    );
    await tester.pumpAndSettle();

    await _submitLogin(tester, s);
    expect(verifierCalls, 0);

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();

    expect(verifierCalls, 1);
    expect(client.nativeLoginCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.videoVerificationRequired), findsOneWidget);
    expect(find.text(s.videoOpenSource), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    client.nativeLoginChallengeUrl = null;
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLogins, [_credentials, _credentials]);
    expect(verifierCalls, 1);
    expect(find.text('native-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('access denial offers the approved source without verifying', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final launchedUrls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'launch') return null;
      launchedUrls.add((call.arguments as Map)['url'] as String);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final client = _TestMissavClient()
      ..nativeLoginError = const MissavAccessDeniedException(
        sourceUrl: 'https://unapproved.example.test/en/api/login',
      );
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));
    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: false, signedIn: false);
        },
      ),
    );
    await tester.pumpAndSettle();
    await _submitLogin(tester, s);

    expect(client.nativeLoginCalls, 1);
    expect(find.text(s.videoAccessDenied), findsOneWidget);
    expect(find.text(s.videoVerificationRequired), findsNothing);
    expect(launchedUrls, isEmpty);
    final openSource = find.text(s.videoOpenSource);
    await tester.ensureVisible(openSource);
    await tester.tap(openSource);
    await tester.pumpAndSettle();

    expect(launchedUrls, [client.originHomeUrl]);
    expect(verifierCalls, 0);
  });

  for (final hasRetryTime in [false, true]) {
    testWidgets(
      hasRetryTime
          ? 'rate limiting shows the local retry time'
          : 'rate limiting without a time asks the user to wait',
      (tester) async {
        final retryAt = hasRetryTime
            ? DateTime.now().toUtc().add(const Duration(hours: 2))
            : null;
        final client = _TestMissavClient()
          ..nativeLoginError = MissavRateLimitException(
            sourceUrl: 'https://missav.ai/en/api/login',
            retryAt: retryAt,
          );
        var verifierCalls = 0;
        final s = await S.delegate.load(const Locale('en'));
        await tester.pumpWidget(
          _app(
            client,
            verifier: (_, _, {required sourceUrl}) async {
              verifierCalls++;
              return (verified: false, signedIn: false);
            },
          ),
        );
        await tester.pumpAndSettle();
        await _submitLogin(tester, s);

        final message = retryAt == null
            ? s.videoRateLimited
            : s.videoRateLimitedUntil(
                DateFormat.yMMMd(
                  s.localeName,
                ).add_jm().format(retryAt.toLocal()),
              );
        expect(find.text(message), findsOneWidget);
        expect(find.text(s.videoVerificationRequired), findsNothing);
        expect(find.byType(TextField), findsNWidgets(2));
        expect(client.nativeLoginCalls, 1);
        expect(verifierCalls, 0);
      },
    );
  }

  testWidgets('invalid credentials stay in the login form', (tester) async {
    final client = _TestMissavClient()..rejectLogin = true;
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: true, signedIn: true);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'viewer@example.test');
    await tester.enterText(find.byType(TextField).last, 'wrong-password');
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 1);
    expect(verifierCalls, 0);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.loginFailed), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('network login failures do not open verification', (
    tester,
  ) async {
    final client = _TestMissavClient()..failLogin = true;
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          verifierCalls++;
          return (verified: true, signedIn: true);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'viewer@example.test');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 1);
    expect(verifierCalls, 0);
    expect(find.text(s.loginFailed), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));
  });

  testWidgets('account page selects the login host', (tester) async {
    final client = _TestMissavClient();

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl}) async {
          return (verified: true, signedIn: true);
        },
      ),
    );
    await tester.pumpAndSettle();

    final s = S.of(tester.element(find.byType(VideoAccountScreen)));
    expect(find.text(s.videoAccountHost), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('missav.ws').last);
    await tester.pumpAndSettle();

    expect(client.accountHostUrl, 'https://missav.ws');
  });
}

const _credentials = (email: 'viewer@example.test', password: 'password');

Future<void> _submitLogin(WidgetTester tester, S s) async {
  await tester.enterText(find.byType(TextField).first, _credentials.email);
  await tester.enterText(find.byType(TextField).last, _credentials.password);
  await tester.tap(find.text(s.login));
  await tester.pumpAndSettle();
}

Widget _app(
  _TestMissavClient client, {
  required _MissavAccountVerifier verifier,
  Future<void> Function()? clearBrowserSession,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
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
    home: const VideoAccountScreen(),
  ),
);

class _TestMissavClient extends MissavClient {
  _TestMissavClient({this.restoredAccountName})
    : super(secureStorage: _TestSecureStorage());

  final String? restoredAccountName;
  bool _loggedIn = false;
  String? _name;
  int browserAccessChecks = 0;
  int logoutCalls = 0;
  final nativeLogins = <({String email, String password})>[];
  int get nativeLoginCalls => nativeLogins.length;
  String? nativeLoginChallengeUrl;
  MissavException? nativeLoginError;
  bool rejectLogin = false;
  bool failLogin = false;

  @override
  String get homeUrl => 'https://missav.ai/cn';

  @override
  bool get isLoggedIn => _loggedIn;

  @override
  String? get accountName => _name;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> checkBrowserAccess({Map<String, dynamic>? browserUser}) async {
    browserAccessChecks++;
    if (restoredAccountName case final name?) confirmAccount(name);
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
    _loggedIn = false;
    _name = null;
    notifyListeners();
  }

  @override
  Future<void> login({required String email, required String password}) async {
    nativeLogins.add((email: email, password: password));
    if (nativeLoginError case final error?) throw error;
    if (nativeLoginChallengeUrl case final challengeUrl?) {
      throw MissavVerificationRequiredException(sourceUrl: challengeUrl);
    }
    if (rejectLogin) {
      throw MissavAuthenticationException(sourceUrl: homeUrl);
    }
    if (failLogin) {
      throw const MissavException('MissAV request failed.');
    }
    confirmAccount('native-viewer');
  }

  void confirmAccount(String name) {
    _loggedIn = true;
    _name = name;
    notifyListeners();
  }
}

class _TestSecureStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
