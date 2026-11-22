import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/src/native_transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/videos/jable_client.dart';
import 'package:iroru/src/videos/jable_verification.dart';
import 'package:iroru/src/videos/missav_browser_adapter.dart';
import 'package:iroru/src/videos/video_login_phase.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  for (final (phase, category, description) in [
    (VideoLoginPhase.browserHandoff, 'state', 'handoff failure'),
    (
      VideoLoginPhase.favoritesConfirmation,
      'accountNotConfirmed',
      'account recheck failure',
    ),
    (VideoLoginPhase.sessionSave, 'platform', 'session save failure'),
  ]) {
    testWidgets(
      'Jable $description keeps the saved session and reports its phase',
      (tester) async {
        final browser = _JableDesktopTransport(
          failHandoff: phase == VideoLoginPhase.browserHandoff,
          confirmHiddenAccount: phase != VideoLoginPhase.favoritesConfirmation,
        );
        final storage = _MemorySecureStorage()..session = _savedSession;
        if (phase == VideoLoginPhase.sessionSave) {
          storage.beforeWrite = () async => throw PlatformException(
            code: 'write-failed',
            message: 'storage-error-detail',
          );
        }
        final logs = <String>[];
        final previousDebugPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) logs.add(message);
        };
        try {
          final (strings, _) = await _openLogin(tester, browser, storage);
          final failure = find.text(phase.failureMessage(strings));
          await tester.tap(find.text(strings.videoLoginComplete));
          await _pumpBrowserUntil(tester, () => failure.evaluate().isNotEmpty);

          expect(storage.session, _savedSession);
          if (phase == VideoLoginPhase.sessionSave) {
            expect(browser.hiddenAccountChecked, isTrue);
            expect(storage.writes.single, contains('session=new'));
          } else {
            expect(storage.writes, isEmpty);
          }
          expect(failure, findsOneWidget);
          expect(
            logs,
            contains(
              startsWith(
                'Jable login failed: stage=${phase.name} category=$category',
              ),
            ),
          );
          expect(logs.join('\n'), isNot(contains('storage-error-detail')));
          await tester.tap(find.text(strings.cancel));
          await tester.pumpAndSettle();
        } finally {
          debugPrint = previousDebugPrint;
        }
      },
      variant: _desktop,
    );
  }

  testWidgets(
    'cancelling an in-flight Jable handoff keeps the saved session',
    (tester) async {
      final allowHandoff = Completer<void>();
      final browser = _JableDesktopTransport(
        beforeHandoff: () => allowHandoff.future,
      );
      final storage = _MemorySecureStorage()..session = _savedSession;
      final (strings, _) = await _openLogin(tester, browser, storage);

      await tester.tap(find.text(strings.videoLoginComplete));
      await _pumpBrowserUntil(tester, () => browser.handoffStarted);
      expect(storage.session, _savedSession);

      await tester.tap(find.text(strings.cancel));
      await tester.pumpAndSettle();
      allowHandoff.complete();
      await _pumpBrowserUntil(tester, () => browser.closed.contains(2));

      expect(storage.session, _savedSession);
      expect(storage.writes, isEmpty);
    },
    variant: _desktop,
  );

  testWidgets('cancelling while Jable saves restores the saved session', (
    tester,
  ) async {
    final allowSave = Completer<void>();
    final browser = _JableDesktopTransport();
    final storage = _MemorySecureStorage()
      ..session = _savedSession
      ..beforeWrite = () => allowSave.future;
    final (strings, _) = await _openLogin(tester, browser, storage);

    await tester.tap(find.text(strings.videoLoginComplete));
    await _pumpBrowserUntil(tester, () => storage.writes.isNotEmpty);
    expect(storage.writes.single, contains('session=new'));
    expect(browser.hiddenAccountChecked, isTrue);
    expect(storage.session, _savedSession);

    await tester.tap(find.text(strings.cancel));
    await tester.pumpAndSettle();
    allowSave.complete();
    await _pumpBrowserUntil(tester, () => browser.closed.contains(2));

    expect(storage.session, _savedSession);
  }, variant: _desktop);

  testWidgets(
    'successful Jable handoff saves the session and keeps the browser',
    (tester) async {
      final browser = _JableDesktopTransport();
      final storage = _MemorySecureStorage()..session = _savedSession;
      final (strings, client) = await _openLogin(tester, browser, storage);

      await tester.tap(find.text(strings.videoLoginComplete));
      await _pumpBrowserUntil(tester, () => storage.session != _savedSession);
      await tester.pumpAndSettle();

      expect(browser.hiddenAccountChecked, isTrue);
      expect(storage.session, contains('session=new'));
      expect(browser.urls.keys, [2]);
      expect(find.text(strings.videoLoginComplete), findsNothing);
      expect(client.account.isLoggedIn, isTrue);
      bool? confirmed;
      final recheck = client.account.checkLogin().then(
        (value) => confirmed = value,
      );
      await _pumpBrowserUntil(tester, () => confirmed != null);
      expect(await recheck, isTrue);
    },
    variant: _desktop,
  );

  test('Android WebView document markup is decoded before HTML parsing', () {
    const markup = '''
      <html><body>
        <div class="video-img-box">Video</div>
        <script>var hlsUrl = "https://media.example/master.m3u8";</script>
      </body></html>
    ''';

    final decoded = jableDocumentMarkup(jsonEncode(markup), android: true);
    final document = html_parser.parse(decoded);

    expect(document.querySelector('.video-img-box'), isNotNull);
    expect(
      document.querySelector('script')!.text,
      contains('hlsUrl = "https://media.example/master.m3u8"'),
    );
  });

  test(
    'a stale browser failure does not detach a newly attached session',
    () async {
      final client = JableClient(secureStorage: _MemorySecureStorage());
      await client.initialize();
      final oldSessionGeneration = client.sessionGeneration;
      final oldNavigation = Completer<void>();
      final allowOldFailure = Completer<void>();
      final oldBrowser = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (uri, _) async => ('<html></html>', uri),
        disposeBrowser: () async {},
      );
      var newBrowserNavigations = 0;
      final newBrowser = MissavBrowserAdapter.jable(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://jable.tv/',
        navigateDocument: (uri, _) async {
          newBrowserNavigations++;
          return ('<html><head><title>New session</title></head></html>', uri);
        },
        disposeBrowser: () async {},
      );

      final oldConnection = () async {
        oldNavigation.complete();
        await allowOldFailure.future;
        final detached = client.restoreNativeTransportIfCurrent(
          expectedAdapter: oldBrowser,
          expectedGeneration: oldSessionGeneration,
          connectionGeneration: 1,
        );
        oldBrowser.close(force: true);
        await oldBrowser.whenClosed;
        expect(detached, isFalse);
      }();
      await oldNavigation.future;
      await client.importVerifiedSession(
        cookieHeader: 'cf_clearance=verified',
        userAgent: 'Browser agent',
        expectedGeneration: oldSessionGeneration,
      );
      client.useVerifiedBrowserTransport(
        newBrowser,
        expectedGeneration: client.sessionGeneration,
        connectionGeneration: 2,
      );
      allowOldFailure.complete();
      await oldConnection;

      final page = await client.browse('https://jable.tv/');

      expect(page.title, 'New session');
      expect(newBrowserNavigations, 1);
      expect(newBrowser.isClosed, isFalse);
      client.dispose();
    },
  );
}

const _savedSession = '{"cookie":"session=previous","userAgent":"Previous UA"}';
const _desktop = TargetPlatformVariant({TargetPlatform.windows});

Future<void> _pumpBrowserUntil(
  WidgetTester tester,
  bool Function() ready,
) async {
  for (var turn = 0; turn < 12 && !ready(); turn++) {
    await tester.pump();
    await tester.runAsync(() async {});
  }
  expect(ready(), isTrue);
}

Future<(S, JableClient)> _openLogin(
  WidgetTester tester,
  _JableDesktopTransport browser,
  _MemorySecureStorage storage,
) async {
  final previousTransport = NativeTransport.debugOverride;
  final previousPathProvider = PathProviderPlatform.instance;
  NativeTransport.debugOverride = browser;
  PathProviderPlatform.instance = _TestPathProvider();
  final client = JableClient(secureStorage: storage);
  addTearDown(() {
    client.dispose();
    NativeTransport.debugOverride = previousTransport;
    PathProviderPlatform.instance = previousPathProvider;
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: S.localizationsDelegates,
      supportedLocales: S.supportedLocales,
      locale: const Locale('en'),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => verifyJableAccess(
            context,
            client,
            sourceUrl: JableClient.origin,
            requireLogin: true,
          ),
          child: const Text('Open Jable login'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open Jable login'));
  await tester.pumpAndSettle();
  return (S.of(tester.element(find.byType(AlertDialog))), client);
}

class _TestPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async => 'jable_test_support';
}

class _JableDesktopTransport extends NativeTransport {
  _JableDesktopTransport({
    this.failHandoff = false,
    this.confirmHiddenAccount = true,
    this.beforeHandoff,
  }) : super.testing();

  final bool failHandoff;
  final bool confirmHiddenAccount;
  final Future<void> Function()? beforeHandoff;
  final urls = <int, String>{};
  final closed = <int>{};
  bool handoffStarted = false;
  bool hiddenAccountChecked = false;

  @override
  Future<T?> invoke<T>(String method, [Object? arguments]) async {
    final args = arguments as Map?;
    switch (method) {
      case 'isWebviewAvailable':
        return true as T;
      case 'create':
        final hidden = args!['openHidden'] == true;
        if (hidden) {
          handoffStarted = true;
          await beforeHandoff?.call();
          if (failHandoff) throw StateError('Hidden browser unavailable.');
        }
        return <Object?, Object?>{'id': hidden ? 2 : 1} as T;
      case 'launch':
      case 'reload':
        final id = args!['viewId'] as int;
        final url = (args['url'] as String?) ?? urls[id]!;
        urls[id] =
            id == 2 && !confirmHiddenAccount && url == JableAccount.favoritesUrl
            ? '${JableClient.origin}/login/'
            : url;
        if (id == 2 && url == JableAccount.favoritesUrl) {
          hiddenAccountChecked = true;
        }
        for (final isLoading in [true, false]) {
          await dispatchEvent(
            MethodCall('onNavigationStateChanged', {
              'id': id,
              'url': urls[id],
              'canGoBack': false,
              'canGoForward': false,
              'isLoading': isLoading,
            }),
          );
        }
        return null;
      case 'evaluateJavaScript':
        final url = urls[args!['viewId']]!;
        final result = switch (args['javaScriptString']) {
          'location.href' => url,
          'navigator.userAgent' => 'Test UA',
          'document.documentElement?.outerHTML ?? ""' =>
            url == JableAccount.favoritesUrl
                ? '<div id="list_videos_my_favourite_videos"></div>'
                : '<html></html>',
          _ => null,
        };
        return jsonEncode(result) as T;
      case 'getAllCookies':
        return <Object?>[
              {
                'name': 'session',
                'value': 'new',
                'domain': 'jable.tv',
                'path': '/',
              },
            ]
            as T;
      case 'close':
        final id = args!['viewId'] as int;
        urls.remove(id);
        await dispatchEvent(MethodCall('onWindowClose', {'id': id}));
        closed.add(id);
        return null;
      case 'setUrlRequestEnabled':
      case 'stop':
        return null;
      default:
        throw MissingPluginException(method);
    }
  }
}

class _MemorySecureStorage implements FlutterSecureStorage {
  String? session;
  final writes = <String?>[];
  Future<void> Function()? beforeWrite;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) return Future<String?>.value(session);
    if (invocation.memberName == #write) {
      return _write(invocation.namedArguments[#value] as String?);
    }
    if (invocation.memberName == #delete) session = null;
    return Future<void>.value();
  }

  Future<void> _write(String? value) async {
    writes.add(value);
    await beforeWrite?.call();
    session = value;
  }
}
