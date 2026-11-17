import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/l10n/app_localizations.dart';
import 'package:kikoeru_flutter/src/providers/audio_provider.dart';
import 'package:kikoeru_flutter/src/videos/missav_client.dart';
import 'package:kikoeru_flutter/src/videos/ui/video_account_screen.dart';
import 'package:kikoeru_flutter/src/videos/video_models.dart';
import 'package:kikoeru_flutter/src/videos/video_providers.dart';

typedef _MissavAccessVerifier =
    Future<bool> Function(
      BuildContext context,
      MissavClient client, {
      required String sourceUrl,
      bool requireLogin,
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
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async =>
            false,
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

  testWidgets('verification button opens the source access check', (
    tester,
  ) async {
    final client = _TestMissavClient();
    final requests = <({String sourceUrl, bool requireLogin})>[];
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          requests.add((sourceUrl: sourceUrl, requireLogin: requireLogin));
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));

    await tester.tap(find.text(s.videoVerifyAccess));
    await tester.pumpAndSettle();
    expect(requests.last, (
      sourceUrl: 'https://missav.ai/cn',
      requireLogin: false,
    ));
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
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          verifierCalls++;
          return true;
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

  testWidgets('native login opens verification and retries automatically', (
    tester,
  ) async {
    const challengeUrl = 'https://missav.ai/en/api/login';
    final client = _TestMissavClient()..nativeLoginChallengeUrl = challengeUrl;
    final requests = <({String sourceUrl, bool requireLogin})>[];
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          requests.add((sourceUrl: sourceUrl, requireLogin: requireLogin));
          client.nativeLoginChallengeUrl = null;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'viewer@example.test');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(requests, [(sourceUrl: challengeUrl, requireLogin: false)]);
    expect(client.nativeLoginCalls, 2);
    expect(find.text(s.videoVerificationRequired), findsNothing);
    expect(find.text('native-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('cancelled verification keeps the login form retryable', (
    tester,
  ) async {
    final client = _TestMissavClient()
      ..nativeLoginChallengeUrl = 'https://missav.ai/en';
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'viewer@example.test');
    await tester.enterText(find.byType(TextField).last, 'password');
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 1);
    expect(client.isLoggedIn, isFalse);
    expect(find.text(s.videoVerificationRequired), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(2));

    client.nativeLoginChallengeUrl = null;
    await tester.tap(find.text(s.login));
    await tester.pumpAndSettle();

    expect(client.nativeLoginCalls, 2);
    expect(find.text('native-viewer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('invalid credentials stay in the login form', (tester) async {
    final client = _TestMissavClient()..rejectLogin = true;
    var verifierCalls = 0;
    final s = await S.delegate.load(const Locale('en'));

    await tester.pumpWidget(
      _app(
        client,
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          verifierCalls++;
          return true;
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
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          verifierCalls++;
          return true;
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
        verifier: (_, _, {required sourceUrl, requireLogin = false}) async {
          return true;
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

Widget _app(
  _TestMissavClient client, {
  required _MissavAccessVerifier verifier,
  Future<void> Function()? clearBrowserSession,
}) => ProviderScope(
  overrides: [
    videoClientProvider.overrideWith((ref) => client),
    missavAccessVerifierProvider.overrideWithValue(verifier),
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
  int nativeLoginCalls = 0;
  String? nativeLoginChallengeUrl;
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
    nativeLoginCalls++;
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
