import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iroru/l10n/app_localizations.dart';
import 'package:iroru/src/services/log_service.dart';
import 'package:iroru/src/utils/global_keys.dart';
import 'package:iroru/src/videos/jable_client.dart';
import 'package:iroru/src/videos/jable_verification.dart';
import 'package:iroru/src/videos/missav_client.dart';
import 'package:iroru/src/videos/missav_browser_adapter.dart';
import 'package:iroru/src/videos/missav_browser_media.dart';
import 'package:iroru/src/videos/missav_verification.dart';
import 'package:iroru/src/videos/video_login_phase.dart';
import 'package:iroru/src/videos/video_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// This mock extends the transitive platform API used by webview_flutter.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final source in ['MissAV', 'Jable']) {
    for (final (size, webWidth) in [
      (const Size(320, 568), 272.0),
      (const Size(390, 844), 342.0),
      (const Size(844, 390), 720.0),
      (const Size(1024, 768), 720.0),
    ]) {
      testWidgets('$source verification fits $size with a larger web area', (
        tester,
      ) async {
        final oldPlatform = WebViewPlatform.instance;
        WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
          debugDefaultTargetPlatformOverride = null;
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
        });
        await tester.pumpWidget(
          const MaterialApp(
            locale: Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: Scaffold(body: SizedBox()),
          ),
        );
        final context = tester.element(find.byType(Scaffold));
        final missav = MissavClient(secureStorage: _MemorySecureStorage());
        final jable = JableClient(secureStorage: _MemorySecureStorage());
        addTearDown(missav.dispose);
        addTearDown(jable.dispose);
        final verification = source == 'MissAV'
            ? verifyMissavAccess(context, missav, sourceUrl: missav.homeUrl)
            : verifyJableAccess(context, jable, sourceUrl: jable.homeUrl);
        await tester.pumpAndSettle();

        final web = tester.getRect(find.byType(WebViewWidget));
        final dialog = tester.getRect(
          find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(web.width, closeTo(webWidth, .01));
        expect(web.height, greaterThan(0));
        expect(dialog.left, greaterThanOrEqualTo(16));
        expect(dialog.right, lessThanOrEqualTo(size.width - 16));
        expect(dialog.top, greaterThanOrEqualTo(24));
        expect(dialog.bottom, lessThanOrEqualTo(size.height - 24));
        if (size.height >= 768) {
          expect(dialog.height, greaterThan(size.height * .85));
        }
        final cancel = find.widgetWithText(TextButton, 'Cancel');
        expect(dialog.contains(tester.getCenter(cancel)), isTrue);
        expect(tester.takeException(), isNull);

        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(await verification, isFalse);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  for (final loginStatus in [200, 401]) {
    test(
      'login keeps the verified browser available for account pages (status=$loginStatus)',
      () async {
        final oldPlatform = WebViewPlatform.instance;
        WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });
        final controller = WebViewController();
        final storage = _MemorySecureStorage();
        final client = MissavClient(secureStorage: storage);
        addTearDown(client.dispose);
        late final MissavBrowserAdapter adapter;
        late final int verifiedGeneration;
        void ensureCurrent() => ensureMissavBrowserConnectionCurrent(
          0,
          null,
          client: client,
          clientGeneration: verifiedGeneration,
          browserAdapter: adapter,
        );
        adapter = MissavBrowserAdapter(
          runJavaScript: (script) async {
            final match = RegExp(r'const request = (.*);').firstMatch(script)!;
            final request = jsonDecode(match.group(1)!) as Map;
            adapter.receiveMessage({
              'id': request['id'],
              'nonce': request['nonce'],
              'origin': MissavClient.origin,
              'status': loginStatus,
              'url': request['url'],
              'headers': {'content-type': 'application/json'},
              'body': loginStatus == 200 ? '{"user":{"name":"viewer"}}' : '{}',
            });
          },
          currentUrl: () => missavMobileSourceUrl(controller),
          navigateDocument: (uri, cancelled) => navigateMissavDocument(
            uri,
            cancelled,
            navigate: (signal) => waitForMissavMobilePage(
              controller,
              uri.toString(),
              cancelSignal: signal,
              ensureActive: () {},
            ),
            read: (_) async => {
              'url': uri.toString(),
              'html':
                  '<html><head><title>Catalog</title></head>'
                  '<body><main></main></body></html>',
            },
            stop: () => controller.runJavaScript('window.stop();'),
            releaseDocument: (_) => parkMissavMobileBrowser(
              controller,
              ensureActive: ensureCurrent,
            ),
          ),
          disposeBrowser: () async {},
          readCookieHeader: () async => 'session=login',
        );
        await client.importVerifiedSession(
          cookieHeader: 'session=verified',
          userAgent: 'Test browser',
        );
        client.useVerifiedBrowserTransport(adapter);
        verifiedGeneration = client.sessionGeneration;
        expect((await client.browse(client.homeUrl)).url, client.homeUrl);
        final writesBeforeLogin = storage.writeCalls;

        final login = client.login(
          email: 'viewer@example.test',
          password: 'sample',
        );
        if (loginStatus == 200) {
          await login;
          expect(storage.writeCalls, greaterThan(writesBeforeLogin));
        } else {
          await expectLater(
            login,
            throwsA(isA<MissavAuthenticationException>()),
          );
          expect(storage.writeCalls, writesBeforeLogin);
        }
        expect(adapter.isClosed, isFalse);
        final page = await client.browse(
          loginStatus == 200 ? client.collectionUrl('history') : client.homeUrl,
        );
        expect(page.title, 'Catalog');
        expect(await controller.currentUrl(), 'about:blank');
        expect(client.sessionGeneration, greaterThan(verifiedGeneration));

        expect(
          () => ensureMissavBrowserConnectionCurrent(
            0,
            null,
            client: client,
            clientGeneration: verifiedGeneration,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => ensureMissavBrowserConnectionCurrent(
            -1,
            null,
            browserAdapter: adapter,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => ensureMissavBrowserConnectionCurrent(
            0,
            Completer<void>()..complete(),
            browserAdapter: adapter,
          ),
          throwsA(isA<StateError>()),
        );
        client.restoreNativeTransport();
        expect(ensureCurrent, throwsA(isA<StateError>()));
      },
    );
  }

  test(
    'idle mobile bridge unloads the website without another network navigation',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      final navigationFinished = Completer<void>();
      final platform = _FakeWebViewPlatform(
        Future.value(const []),
        onLoadHtml: () => navigationFinished.future,
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      final controller = WebViewController();
      final browser = controller.platform as _FakeWebViewController;
      var parked = false;
      final parking = parkMissavMobileBrowser(
        controller,
      ).then((_) => parked = true);
      addTearDown(() async {
        if (!navigationFinished.isCompleted) navigationFinished.complete();
        await parking;
      });
      await browser.htmlLoadStarted.future;
      expect(parked, isFalse);
      // A late finish event from the old website cannot release the bridge load.
      browser._navigationDelegate!.pageFinished!('https://missav.ai/cn');
      await Future<void>.delayed(Duration.zero);
      expect(parked, isFalse);
      navigationFinished.complete();
      await parking;
      expect(browser.networkNavigations, 0);
      expect(await controller.currentUrl(), 'about:blank');
      expect(await missavMobileSourceUrl(controller), 'https://missav.ai/');
      expect(browser.htmlDocument, isNot(contains('<script')));
    },
  );

  test(
    'mobile source gate rejects a foreign or opaque document origin',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      final controller = WebViewController();
      final browser = controller.platform as _FakeWebViewController;
      for (final url in [
        'https://other.example/',
        'about:blank',
        'http://missav.ai/',
      ]) {
        browser.documentUrl = url;
        expect(await missavMobileSourceUrl(controller), isNull, reason: url);
      }
    },
  );

  test(
    'document requests release the source page before the next request',
    () async {
      final released = Completer<void>();
      final releaseStarted = Completer<void>();
      var sourcePageRetained = true;
      var secondNavigationStarted = false;
      late final MissavBrowserAdapter adapter;
      adapter = MissavBrowserAdapter(
        runJavaScript: (_) async {},
        currentUrl: () async => 'https://missav.ai/cn',
        navigateDocument: (uri, cancelled) => navigateMissavDocument(
          uri,
          cancelled,
          navigate: (_) async {
            if (releaseStarted.isCompleted) secondNavigationStarted = true;
          },
          read: (_) async => {
            'url': uri.toString(),
            'html': '<html>catalog</html>',
          },
          stop: () async {},
          releaseDocument: (_) async {
            if (!releaseStarted.isCompleted) releaseStarted.complete();
            await released.future;
            sourcePageRetained = false;
          },
        ),
        disposeBrowser: () async {},
      );
      addTearDown(() async {
        if (!released.isCompleted) released.complete();
        adapter.close();
        await adapter.whenClosed;
      });

      final first = adapter.loadDocument(Uri.parse('https://missav.ai/cn'));
      await Future<void>.delayed(Duration.zero);
      expect(releaseStarted.isCompleted, isTrue);
      var firstFinished = false;
      unawaited(first.then((_) => firstFinished = true));
      final second = adapter.loadDocument(
        Uri.parse('https://missav.ai/cn/new'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(firstFinished, isFalse);
      expect(secondNavigationStarted, isFalse);
      released.complete();
      expect(await first, '<html>catalog</html>');
      expect(await second, '<html>catalog</html>');
      expect(sourcePageRetained, isFalse);
      expect(secondNavigationStarted, isTrue);
    },
  );

  for (final cancel in [false, true]) {
    test(
      'failed hidden navigation stops before unloading (cancel=$cancel)',
      () async {
        final cancelled = Completer<void>();
        final started = Completer<void>();
        final stopStarted = Completer<void>();
        final stopFinished = Completer<void>();
        var stopped = false;
        var released = false;
        final document = navigateMissavDocument(
          Uri.parse('https://missav.ai/cn'),
          cancelled.future,
          navigate: (signal) async {
            started.complete();
            if (cancel) {
              await signal.future;
              throw StateError('cancelled');
            }
          },
          read: (_) async => throw const FormatException('invalid document'),
          stop: () async {
            stopStarted.complete();
            await stopFinished.future;
            stopped = true;
          },
          releaseDocument: (documentRead) async {
            expect(documentRead, isFalse);
            expect(stopped, isTrue);
            released = true;
          },
        );
        final outcome = expectLater(
          document,
          throwsA(cancel ? isA<StateError>() : isA<FormatException>()),
        );
        await started.future;
        if (cancel) cancelled.complete();
        await stopStarted.future;
        expect(released, isFalse);
        stopFinished.complete();
        await outcome;
        expect(released, isTrue);
      },
    );
  }

  test('late parking errors never stop a replacement page', () async {
    final cancelled = Completer<void>();
    final releaseStarted = Completer<void>();
    final releaseFinished = Completer<void>();
    var stops = 0;
    final document = navigateMissavDocument(
      Uri.parse('https://missav.ai/cn'),
      cancelled.future,
      navigate: (_) async {},
      read: (_) async => {
        'url': 'https://missav.ai/cn',
        'html': '<html></html>',
      },
      stop: () async => stops++,
      releaseDocument: (_) async {
        releaseStarted.complete();
        await releaseFinished.future;
        throw StateError('old browser closed');
      },
    );
    final outcome = expectLater(document, throwsA(isA<StateError>()));
    await releaseStarted.future;
    cancelled.complete();
    releaseFinished.complete();
    await outcome;
    expect(stops, 0);
  });

  test('replaced mobile sessions cannot load a late bridge document', () async {
    final oldPlatform = WebViewPlatform.instance;
    WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
    addTearDown(() {
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
    });
    final controller = WebViewController();
    final browser = controller.platform as _FakeWebViewController;
    var checks = 0;
    await expectLater(
      parkMissavMobileBrowser(
        controller,
        ensureActive: () {
          if (++checks == 2) throw StateError('session replaced');
        },
      ),
      throwsA(isA<StateError>()),
    );
    expect(browser.htmlLoadStarted.isCompleted, isFalse);
    expect(browser.networkNavigations, 0);
  });

  test('Android accepts the verified browser document', () async {
    const html = '<html><a href="/logout">退出登录</a></html>';
    final document = jsonEncode({'url': 'https://missav.ai/cn', 'html': html});
    var stopped = false;

    final result = await navigateMissavDocument(
      Uri.parse('https://missav.ai/cn'),
      Completer<void>().future,
      navigate: (_) async {},
      // Android evaluateJavascript encodes string results as JSON strings.
      read: (_) async => jsonEncode(document),
      stop: () async => stopped = true,
    );

    expect(result, html);
    expect(stopped, isFalse);
  });

  test('captures source recommendation context before parking', () async {
    const context = {
      'userId': 'source-visitor',
      'scenario': 'mobile-home-recommended',
    };
    var parked = false;
    final result = await navigateMissavDocument(
      Uri.parse('https://missav.ai/cn'),
      Completer<void>().future,
      navigate: (_) async {},
      read: (_) async {
        expect(parked, isFalse);
        return {
          'url': 'https://missav.ai/cn',
          'html': '<html><body>Source homepage</body></html>',
          'recommendationContext': context,
        };
      },
      stop: () async {},
      releaseDocument: (_) async => parked = true,
    );
    expect(parked, isTrue);
    expect(result, contains('id="kiko-missav-recommendation-context"'));
    expect(result, contains(jsonEncode(context)));
  });

  test('accepts a document returned as JSON or a platform map', () async {
    const document = {
      'url': 'https://missav.ai/en',
      'html': '<html><a href="/logout">Log out</a></html>',
    };
    for (final result in [jsonEncode(document), document]) {
      expect(
        await navigateMissavDocument(
          Uri.parse('https://missav.ai/en'),
          Completer<void>().future,
          navigate: (_) async {},
          read: (_) async => result,
          stop: () async {},
        ),
        document['html'],
      );
    }
  });

  for (final (status, challenge) in <(int?, bool)>[
    (401, false),
    (403, false),
    (500, false),
    (200, false),
    (0, false),
    (null, false),
    (403, true),
  ]) {
    test(
      'browser collection honors document HTTP $status (challenge=$challenge)',
      () async {
        final client = MissavClient(secureStorage: _MemorySecureStorage());
        addTearDown(client.dispose);
        MissavBrowserAdapter buildAdapter() {
          late final MissavBrowserAdapter adapter;
          adapter = MissavBrowserAdapter(
            runJavaScript: (script) async {
              final match = RegExp(
                r'const request = (.*);',
              ).firstMatch(script)!;
              final request = jsonDecode(match.group(1)!) as Map;
              adapter.receiveMessage({
                'id': request['id'],
                'nonce': request['nonce'],
                'origin': MissavClient.origin,
                'status': 200,
                'url': request['url'],
                'headers': {'content-type': 'application/json'},
                'body': '{"user":{"name":"viewer"}}',
              });
            },
            currentUrl: () async => 'https://missav.ai/cn',
            navigateDocument: (uri, cancelled) => navigateMissavDocument(
              uri,
              cancelled,
              navigate: (_) async {},
              read: (_) async => {
                'url': uri.toString(),
                'html': challenge
                    ? '<html><title>Just a moment...</title></html>'
                    : '<html><body><main></main></body></html>',
                'responseStatus': status,
              },
              stop: () async {},
            ),
            disposeBrowser: () async {},
            readCookieHeader: () async => 'session=viewer',
          );
          return adapter;
        }

        client.useVerifiedBrowserTransport(buildAdapter());
        await client.login(email: 'viewer@example.test', password: 'sample');
        expect(client.isLoggedIn, isTrue);

        client.useVerifiedBrowserTransport(buildAdapter());
        final collection = client.browse(client.collectionUrl('favorites'));
        if (status != null && status >= 400) {
          await expectLater(
            collection,
            throwsA(
              challenge
                  ? isA<MissavVerificationRequiredException>()
                  : status == 401
                  ? isA<MissavAuthenticationException>()
                  : status == 403
                  ? isA<MissavAccessDeniedException>()
                  : isA<MissavException>().having(
                      (error) => error.message,
                      'message',
                      contains('HTTP $status'),
                    ),
            ),
          );
        } else {
          expect((await collection).videos, isEmpty);
        }
        expect(client.isLoggedIn, status != 401);
      },
    );
  }

  test(
    'does not treat an invalid browser document as a verification challenge',
    () async {
      final document = jsonEncode({
        'url': 'https://other.example/cn',
        'html': '<html>Not the source</html>',
      });
      for (final result in [document, jsonEncode(document)]) {
        var stopped = false;
        await expectLater(
          navigateMissavDocument(
            Uri.parse('https://missav.ai/cn'),
            Completer<void>().future,
            navigate: (_) async {},
            read: (_) async => result,
            stop: () async => stopped = true,
          ),
          throwsA(
            allOf(
              isA<MissavException>(),
              isNot(isA<MissavVerificationRequiredException>()),
            ),
          ),
        );
        expect(stopped, isTrue);
      }
    },
  );

  test(
    'desktop cancellation waits for the old navigation completion',
    () async {
      final browser = _DesktopBrowser();
      var finished = false;
      final stopped = stopMissavDesktopNavigation(browser).then((_) {
        finished = true;
      });
      await browser.stopRequested.future;
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      browser.state.value = const WebviewNavigationState(
        url: 'https://missav.ai/cn',
        isLoading: false,
      );
      await stopped;
      expect(finished, isTrue);
      browser.state.dispose();
    },
  );

  test('verification stays on the exact HTTPS source origin', () {
    expect(isMissavVerificationUrl('https://missav.ai/dm247/cn'), isTrue);
    expect(isMissavVerificationUrl('https://missav.ai:443/cn'), isTrue);
    expect(isMissavVerificationUrl('https://missav.ws/cn'), isFalse);
    expect(isMissavVerificationUrl('https://missav.live/cn'), isFalse);
    for (final url in [
      'http://missav.ai/cn',
      'https://missav.ai:444/cn',
      'https://missav.ai.example.com/cn',
      'https://cdn.missav.ai/cn',
      'https://user@missav.ai/cn',
      'javascript:alert(1)',
      'about:blank',
      'not a URL',
    ]) {
      expect(isMissavVerificationUrl(url), isFalse, reason: url);
    }
  });

  test(
    'stale Android proxy cleanup cannot release a newer configuration',
    () async {
      const channel = MethodChannel('com.meteor.kikoeruflutter/missav_browser');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final oldOwner = await configureMissavAndroidProxy();
      final newOwner = await configureMissavAndroidProxy();
      await releaseMissavAndroidProxy(oldOwner);

      expect(calls, ['configureProxy', 'configureProxy']);
      await releaseMissavAndroidProxy(newOwner);
      await releaseMissavAndroidProxy(newOwner);
      expect(calls, ['configureProxy', 'configureProxy', 'resetProxy']);
    },
  );

  test('Android cookie reads use the canonical browser session', () async {
    const channel = MethodChannel('com.meteor.kikoeruflutter/missav_browser');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'session=value==';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    expect(await missavMobileCookieHeader(android: true), 'session=value==');
    expect(await missavMobileCookieHeader(android: true), 'session=value==');

    expect(calls.map((call) => call.method), ['getCookies', 'getCookies']);
    expect(calls.map((call) => call.arguments), [isNull, isNull]);
  });

  test('mobile document fake honors the requested ready state', () async {
    final browser = _FakeWebViewController(
      const PlatformWebViewControllerCreationParams(),
      initialUrl: 'https://missav.ai/cn',
    );
    const navigationReady = 'window.__kikofluMissavNavigationPending !== true';
    for (final (state, documentReady, pageReady) in [
      ('loading', false, false),
      ('interactive', true, false),
      ('complete', true, true),
    ]) {
      browser.documentReadyState = state;
      expect(
        await browser.runJavaScriptReturningResult(
          "$navigationReady && document.readyState !== 'loading'",
        ),
        documentReady,
      );
      expect(
        await browser.runJavaScriptReturningResult(
          "$navigationReady && document.readyState === 'complete'",
        ),
        pageReady,
      );
    }
  });

  test(
    'Android document navigation reads a new DOM before page finish',
    () async {
      const url = 'https://missav.ai/cn';
      const html = '<html><body>Ready document</body></html>';
      final oldPlatform = WebViewPlatform.instance;
      final loadStarted = Completer<void>();
      final finishLoad = Completer<void>();
      WebViewPlatform.instance = _FakeWebViewPlatform(
        Future.value(const []),
        initialUrl: url,
        onLoadRequest: (_) async {
          loadStarted.complete();
          await finishLoad.future;
        },
      );
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      final controller = WebViewController();
      final browser = controller.platform as _FakeWebViewController;
      final oldDocumentCheck = browser.nextDocumentReadinessCheck();
      var read = false;
      var stopped = false;
      var released = false;
      var finished = false;
      final navigation =
          navigateMissavDocument(
            Uri.parse(url),
            Completer<void>().future,
            navigate: (signal) => waitForMissavMobilePage(
              controller,
              url,
              cancelSignal: signal,
              ensureActive: () {},
              documentOnly: true,
              restoringAccount: true,
            ),
            read: (_) async {
              expect(finishLoad.isCompleted, isFalse);
              expect(released, isFalse);
              read = true;
              return {'url': url, 'html': html};
            },
            stop: () async => stopped = true,
            releaseDocument: (documentRead) async {
              expect(documentRead, isTrue);
              released = true;
            },
          ).then((document) {
            finished = true;
            return document;
          });

      await loadStarted.future;
      await oldDocumentCheck;
      await Future<void>.delayed(Duration.zero);
      expect(read, isFalse);
      expect(finished, isFalse);

      final challengeCheck = browser.nextDocumentReadinessCheck();
      browser.documentNavigationPending = false;
      browser.documentReadyState = 'interactive';
      browser.cloudflareChallenge = true;
      await challengeCheck;
      await Future<void>.delayed(Duration.zero);
      expect(read, isFalse);
      expect(finished, isFalse);

      browser.cloudflareChallenge = false;
      expect(await navigation, html);
      expect(finishLoad.isCompleted, isFalse);
      expect(released, isTrue);
      expect(stopped, isFalse);

      finishLoad.complete();
    },
  );

  test('background restore reports a persistent verification page', () async {
    final oldPlatform = WebViewPlatform.instance;
    final finishLoad = Completer<void>();
    WebViewPlatform.instance = _FakeWebViewPlatform(
      Future.value(const []),
      initialUrl: MissavClient.accountCheckUrl,
      onLoadRequest: (_) => finishLoad.future,
    );
    addTearDown(() {
      finishLoad.complete();
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
    });
    final controller = WebViewController();
    final browser = controller.platform as _FakeWebViewController;
    browser.cloudflareChallenge = true;
    await expectLater(
      waitForMissavMobilePage(
        controller,
        MissavClient.accountCheckUrl,
        ensureActive: () {},
        documentOnly: true,
        restoringAccount: true,
      ).timeout(const Duration(seconds: 10)),
      throwsA(isA<MissavVerificationRequiredException>()),
    );
  });

  test(
    'Android document navigation preserves cancellation and main-frame errors',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      for (final (failWithMainFrameError, pendingLoadRequest) in [
        (false, false),
        (true, false),
        (true, true),
      ]) {
        const url = 'https://missav.ai/cn';
        final loadStarted = Completer<void>();
        final finishLoad = Completer<void>();
        final finishLoadRequest = Completer<void>();
        final platform = _FakeWebViewPlatform(
          Future.value(const []),
          initialUrl: url,
          onLoadRequest: (_) async {
            loadStarted.complete();
            await finishLoad.future;
          },
          loadRequestCompletion: pendingLoadRequest
              ? finishLoadRequest.future
              : null,
        );
        WebViewPlatform.instance = platform;
        final controller = WebViewController();
        final browser = controller.platform as _FakeWebViewController;
        final cancelled = Completer<void>();
        var reads = 0;
        var stopped = false;
        var released = false;
        final navigation = navigateMissavDocument(
          Uri.parse(url),
          cancelled.future,
          navigate: (signal) => waitForMissavMobilePage(
            controller,
            url,
            cancelSignal: signal,
            ensureActive: () {},
            documentOnly: true,
            restoringAccount: true,
          ),
          read: (_) async {
            reads++;
            return {'url': url, 'html': '<html></html>'};
          },
          stop: () async => stopped = true,
          releaseDocument: (documentRead) async {
            expect(documentRead, isFalse);
            released = true;
          },
        );

        await loadStarted.future;
        if (!pendingLoadRequest) {
          await browser.verificationReadyCheckStarted.future;
        }
        if (failWithMainFrameError) {
          browser._navigationDelegate!.webResourceError!(
            WebResourceError(
              errorCode: -2,
              description: 'Main document failed.',
              isForMainFrame: true,
              url: pendingLoadRequest ? url : null,
            ),
          );
        } else {
          cancelled.complete();
        }

        await expectLater(
          navigation.timeout(const Duration(seconds: 1)),
          throwsA(
            failWithMainFrameError
                ? isA<PlatformException>().having(
                    (e) => e.code,
                    'code',
                    'webview/load/-2',
                  )
                : isA<StateError>(),
          ),
        );
        expect(reads, 0);
        expect(stopped, isTrue);
        expect(released, isTrue);
        finishLoad.complete();
        finishLoadRequest.complete();
      }
    },
  );

  test(
    'mobile navigation ignores old bridge and empty-document finishes',
    () async {
      for (final (hasRoot, rootId) in [
        (true, 'kikoflu-browser-bridge'),
        (false, null),
      ]) {
        final oldPlatform = WebViewPlatform.instance;
        final loadStarted = Completer<void>();
        final finishLoad = Completer<void>();
        final platform = _FakeWebViewPlatform(
          Completer<List<WebViewCookie>>().future,
          initialUrl: null,
          onLoadRequest: (_) async {
            loadStarted.complete();
            await finishLoad.future;
          },
        );
        WebViewPlatform.instance = platform;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });

        final controller = WebViewController();
        final browser = controller.platform as _FakeWebViewController;
        browser.documentUrl = 'https://missav.ai/';
        browser.hasDocumentElement = hasRoot;
        browser.documentElementId = rootId;
        var finished = false;
        final navigation = waitForMissavMobilePage(
          controller,
          'https://missav.ai/cn',
          ensureActive: () {},
        ).then((_) => finished = true);
        await loadStarted.future;

        browser._navigationDelegate!.pageFinished!('https://missav.ai/');
        await browser.verificationReadyCheckStarted.future;
        await Future<void>.delayed(Duration.zero);
        expect(await controller.currentUrl(), isNull);
        expect(finished, isFalse);

        finishLoad.complete();
        await navigation;
        expect(await controller.currentUrl(), 'https://missav.ai/cn');
        expect(finished, isTrue);
      }
    },
  );

  test(
    'a missing document root fails the document read without markup access',
    () async {
      var stopped = false;
      var released = false;

      await expectLater(
        navigateMissavDocument(
          Uri.parse('https://missav.ai/cn'),
          Completer<void>().future,
          navigate: (_) async {},
          read: (script) async {
            expect(script, contains('if (!root) return null;'));
            return null;
          },
          stop: () async => stopped = true,
          releaseDocument: (documentRead) async {
            expect(documentRead, isFalse);
            released = true;
          },
        ),
        throwsA(isA<MissavException>()),
      );

      expect(stopped, isTrue);
      expect(released, isTrue);
    },
  );

  test('only live root cookies for the source enter the native session', () {
    final now = DateTime.now();
    final cookies = [
      _cookie(
        'clearance',
        domain: '.missav.ai',
        expires: now.add(const Duration(days: 1)),
      ),
      _cookie('session', httpOnly: true, sessionOnly: true),
      _cookie('expired', expires: now.subtract(const Duration(days: 1))),
      _cookie('other', domain: 'media.example.com'),
      _cookie('suffix', domain: 'missav.ai.example.com'),
      _cookie('subdomain', domain: 'cdn.missav.ai'),
      _cookie('path', path: '/account'),
    ];
    expect(
      missavVerificationCookieHeader(cookies),
      'clearance=value; session=value',
    );
  });

  test(
    'WebView2 terminating NUL does not discard or corrupt source cookies',
    () {
      expect(
        missavVerificationCookieHeader([
          WebviewCookie(
            name: 'session\u0000',
            value: 'value==\u0000',
            domain: '.missav.ai\u0000',
            path: '/\u0000',
            expires: null,
            secure: true,
            httpOnly: true,
            sessionOnly: true,
          ),
        ]),
        'session=value==',
      );
    },
  );

  test('cookies from other official hosts stay out of the session', () {
    final cookies = [
      _cookie('mirror', domain: '.missav.ws'),
      _cookie('canonical', domain: 'missav.ai'),
      _cookie('live', domain: 'missav.live'),
    ];
    expect(missavVerificationCookieHeader(cookies), 'canonical=value');
  });

  test(
    'a cancelled cookie read cannot import a late browser session',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      final cookies = Completer<List<WebViewCookie>>();
      final webViewPlatform = _FakeWebViewPlatform(cookies.future);
      WebViewPlatform.instance = webViewPlatform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.initialize();
      final initialGeneration = client.sessionGeneration;
      final cancellation = Completer<void>();
      final connection = connectMissavBrowserSession(
        client,
        mobile: WebViewController(),
        cancelSignal: cancellation,
      );

      await webViewPlatform.cookiesRequested.future.timeout(
        const Duration(seconds: 5),
      );
      cancellation.complete();
      await expectLater(connection, throwsA(isA<StateError>()));

      cookies.complete([
        const WebViewCookie(
          name: 'session',
          value: 'late',
          domain: 'missav.ai',
        ),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(client.sessionGeneration, initialGeneration);
      expect(storage.writeCalls, 0);
    },
  );

  test(
    'stale saved-session recovery is rejected before browser setup',
    () async {
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);
      await client.initialize();
      final generation = client.sessionGeneration;

      await expectLater(
        connectMissavBrowserSession(
          client,
          expectedGeneration: generation - 1,
          checkAccess: false,
          forAccountRestore: true,
        ),
        throwsA(isA<StateError>()),
      );
      expect(client.sessionGeneration, generation);
    },
  );

  test(
    'cancelling recovery releases a WebView with a pending navigation',
    () async {
      final oldPlatform = WebViewPlatform.instance;
      final navigationStarted = Completer<void>();
      final nativeNavigation = Completer<void>();
      final webViewPlatform = _FakeWebViewPlatform(
        Future.value([]),
        loadRequestCompletion: nativeNavigation.future,
        onLoadRequest: (params) async {
          if (params.uri.scheme == 'https') {
            navigationStarted.complete();
          }
        },
      );
      WebViewPlatform.instance = webViewPlatform;
      addTearDown(() {
        nativeNavigation.complete();
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=stored',
        userAgent: 'stored-agent',
      );
      final cancelSignal = Completer<void>();
      final connection = connectMissavBrowserSession(
        client,
        mobile: WebViewController(),
        cancelSignal: cancelSignal,
        expectedGeneration: client.sessionGeneration,
        preserveMobilePageOnFailure: false,
        checkAccess: false,
        forAccountRestore: true,
      );
      final rejected = expectLater(
        connection.timeout(const Duration(seconds: 2)),
        throwsA(isA<StateError>()),
      );
      await navigationStarted.future;
      cancelSignal.complete();
      await rejected;
      expect(webViewPlatform.lastController!.networkNavigations, 2);
      expect(storage.cookie, 'session=stored');
      expect(client.isLoggedIn, isFalse);
    },
  );

  testWidgets(
    'saved-session recovery skips import and keeps the stored session',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      var mediaChannelAttempts = 0;
      WebViewPlatform.instance = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'stored',
            domain: 'missav.ai',
          ),
        ]),
        onMediaChannel: () => mediaChannelAttempts++,
      );
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=stored',
        userAgent: 'stored-agent',
      );
      final generation = client.sessionGeneration;
      final storedValues = Map<String, String>.of(storage.values);

      await tester.runAsync(() async {
        final connection = await _pumpUntilComplete(
          tester,
          connectMissavBrowserSession(
            client,
            mobile: WebViewController(),
            expectedGeneration: generation,
            checkAccess: false,
            preserveMobilePageOnFailure: false,
            forAccountRestore: true,
          ),
        );
        expect(connection.signedIn, isFalse);
      });

      expect(client.sessionGeneration, generation);
      expect(storage.values, equals(storedValues));
      expect(storage.cookie, isNotNull);
      expect(mediaChannelAttempts, 0);
      final page =
          (WebViewPlatform.instance as _FakeWebViewPlatform).lastController!;
      const favorites = '${MissavClient.origin}/en/saved';
      expect(page.requestedUrls, [favorites]);
      page.showSignOutOnSnapshot = 2;
      await tester.runAsync(() async {
        expect(
          await _pumpUntilComplete(tester, client.restoreAccount()),
          isTrue,
        );
      });
      expect(page.requestedUrls, [favorites]);
      expect(client.isLoggedIn, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'failed saved-session recovery keeps the stored cookie',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      WebViewPlatform.instance = _FakeWebViewPlatform(Future.value(const []));
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=stored',
        userAgent: 'stored-agent',
      );
      final generation = client.sessionGeneration;
      final storedValues = Map<String, String>.of(storage.values);

      await tester.runAsync(() async {
        final error = await _pumpUntilComplete(
          tester,
          connectMissavBrowserSession(
            client,
            mobile: WebViewController(),
            expectedGeneration: generation,
            checkAccess: false,
            preserveMobilePageOnFailure: false,
            forAccountRestore: true,
          ),
        ).then<Object?>((_) => null, onError: (Object error) => error);
        expect(error, isA<StateError>());
      });

      expect(client.sessionGeneration, generation);
      expect(storage.values, equals(storedValues));
      expect(storage.cookie, isNotNull);
      expect(client.hasRestorableSession, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'failed account verification does not replace the stored session',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      final platform = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'browser',
            domain: 'missav.ai',
          ),
        ]),
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final mobile = WebViewController();
      final page = mobile.platform as _FakeWebViewController;
      page.runtimeUser = {'username': 'browser-viewer'};
      var reads = 0;
      page.responseStatusFor = (_) => ++reads == 1 ? 200 : 500;
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=stored',
        userAgent: 'stored-agent',
      );
      final generation = client.sessionGeneration;
      final storedValues = Map<String, String>.of(storage.values);

      await tester.runAsync(() async {
        final error = await _pumpUntilComplete(
          tester,
          connectMissavBrowserSession(
            client,
            mobile: mobile,
            checkAccess: true,
            forAccountRestore: true,
          ),
        ).then<Object?>((_) => null, onError: (Object error) => error);
        expect(error, isA<MissavException>());
      });

      expect(client.sessionGeneration, generation);
      expect(storage.values, equals(storedValues));
      expect(storage.cookie, isNotNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'saved-session confirmation preserves a browser verification challenge',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      final platform = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'stored',
            domain: 'missav.ai',
          ),
        ]),
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final mobile = WebViewController();
      final page = mobile.platform as _FakeWebViewController;
      page.htmlDocument =
          '<html><head><title>Just a moment...</title></head></html>';
      page.cloudflareChallenge = true;
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=stored',
        userAgent: 'stored-agent',
      );
      final generation = client.sessionGeneration;
      final storedValues = Map<String, String>.of(storage.values);

      await tester.runAsync(() async {
        final error = await _pumpUntilComplete(
          tester,
          connectMissavBrowserSession(
            client,
            mobile: mobile,
            expectedGeneration: generation,
            checkAccess: true,
            preserveMobilePageOnFailure: false,
            forAccountRestore: true,
          ),
        ).then<Object?>((_) => null, onError: (Object error) => error);
        expect(error, isA<MissavVerificationRequiredException>());
      });

      expect(client.sessionGeneration, generation);
      expect(storage.values, equals(storedValues));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test(
    'an account snapshot cannot restore a replaced browser session',
    () async {
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);
      final reading = Completer<void>();
      final document = Completer<Object?>();
      final adapter = MissavBrowserAdapter(
        runJavaScript: (_) async {},
        currentUrl: () async => client.homeUrl,
        navigateDocument: (uri, cancelled) => navigateMissavDocument(
          uri,
          cancelled,
          navigate: (_) async {},
          read: (_) {
            reading.complete();
            return document.future;
          },
          stop: () async {},
        ),
        disposeBrowser: () async {},
      );
      client.useVerifiedBrowserTransport(adapter);
      final result = expectLater(
        client.checkBrowserAccess(
          browserUser: {'username': 'old-login-viewer'},
        ),
        throwsA(isA<MissavException>()),
      );
      await reading.future;
      client.restoreNativeTransport();
      document.complete({
        'url': client.homeUrl,
        'html': '<html><body x-data="{user: null}"></body></html>',
        'runtimeUser': {'username': 'old-browser-viewer'},
      });
      await result;
      expect(client.isLoggedIn, isFalse);
      expect(client.accountName, isNull);
    },
  );

  testWidgets(
    'required login navigates directly to favorites and accepts only its account',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      late final _FakeWebViewPlatform platform;
      platform = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'verified',
            domain: 'missav.ai',
          ),
        ]),
        initialUrl: 'https://missav.ai/cn',
        onLoadRequest: (params) async {
          final page = platform.lastController!;
          if (params.uri.pathSegments.lastOrNull == 'saved') {
            page.favoritesHtmlDocument = _favoritesUserMarkup(
              'favorites-viewer',
            );
          } else {
            page.runtimeUser = {'username': 'stale-home-viewer'};
          }
        },
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final mobile = WebViewController();
      final sourcePage = mobile.platform as _FakeWebViewController;
      sourcePage.runtimeUser = {'username': 'stale-home-viewer'};
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);
      var loginPageReads = 0;

      await tester.runAsync(() async {
        final connection = await _pumpUntilComplete(
          tester,
          connectMissavBrowserSession(
            client,
            mobile: mobile,
            requireLogin: true,
            readLoginPage: (_) async {
              loginPageReads++;
              return {
                'url': 'https://example.invalid/',
                'runtimeUser': {'username': 'untrusted-home-viewer'},
              };
            },
          ),
        );
        expect(connection.signedIn, isTrue);
        expect(connection.importedSession, isFalse);
      });
      await tester.pumpAndSettle();
      expect(sourcePage.requestedUrls, [client.collectionUrl('favorites')]);
      expect(loginPageReads, 0);
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'favorites-viewer');
    },
  );

  testWidgets('media starts on demand and can retry without signing out', (
    tester,
  ) async {
    final oldPlatform = WebViewPlatform.instance;
    var mediaChannelAttempts = 0;
    final mediaChannelStarted = Completer<void>();
    final mediaChannelRelease = Completer<void>();
    final platform = _FakeWebViewPlatform(
      Future.value([
        const WebViewCookie(
          name: 'session',
          value: 'verified',
          domain: 'missav.ai',
        ),
      ]),
      failMediaChannel: true,
      mediaChannelDelay: mediaChannelRelease.future,
      onMediaChannel: () {
        mediaChannelAttempts++;
        if (!mediaChannelStarted.isCompleted) mediaChannelStarted.complete();
      },
    );
    WebViewPlatform.instance = platform;
    addTearDown(() {
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      if (!mediaChannelRelease.isCompleted) mediaChannelRelease.complete();
    });
    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
    );
    final mobile = WebViewController();
    final sourcePage = mobile.platform as _FakeWebViewController;
    sourcePage.favoritesHtmlDocument = _favoritesUserMarkup('browser-viewer');
    final client = MissavClient(secureStorage: _MemorySecureStorage());
    addTearDown(client.dispose);

    await tester.runAsync(() async {
      final connection = await _pumpUntilComplete(
        tester,
        connectMissavBrowserSession(client, mobile: mobile, requireLogin: true),
      );
      expect(connection.signedIn, isTrue);
      expect(mediaChannelAttempts, 0);

      Future<VideoStream> prepare() =>
          client.prepareMediaStream(_relayVideo, _relayStream);
      final unavailable = throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Media relay unavailable.',
        ),
      );
      final failures = Future.wait([
        expectLater(prepare(), unavailable),
        expectLater(prepare(), unavailable),
      ]);
      await _pumpUntilComplete(tester, mediaChannelStarted.future);
      expect(mediaChannelAttempts, 1);
      mediaChannelRelease.complete();
      await _pumpUntilComplete(tester, failures);
      expect(mediaChannelAttempts, 1);
      expect(client.isLoggedIn, isTrue);
      expect(client.accountName, 'browser-viewer');
      expect(await mobile.currentUrl(), client.collectionUrl('favorites'));

      platform.failMediaChannel = false;
      final routed = await _pumpUntilComplete(tester, prepare());
      expect(Uri.parse(routed.url).host, '127.0.0.1');
      expect(routed.headers, isEmpty);
      expect((await prepare()).url, routed.url);
      expect(mediaChannelAttempts, 2);
      await client.importVerifiedSession(
        cookieHeader: 'session=verified',
        userAgent: 'test-browser',
      );
    });
    await tester.pumpAndSettle();
  });

  testWidgets('replacing the account cancels a pending media relay', (
    tester,
  ) async {
    final oldPlatform = WebViewPlatform.instance;
    var mediaChannelAttempts = 0;
    final mediaChannelStarted = Completer<void>();
    final mediaChannelRelease = Completer<void>();
    final platform = _FakeWebViewPlatform(
      Future.value([
        const WebViewCookie(
          name: 'session',
          value: 'verified',
          domain: 'missav.ai',
        ),
      ]),
      mediaChannelDelay: mediaChannelRelease.future,
      onMediaChannel: () {
        mediaChannelAttempts++;
        if (!mediaChannelStarted.isCompleted) mediaChannelStarted.complete();
      },
    );
    WebViewPlatform.instance = platform;
    addTearDown(() {
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      if (!mediaChannelRelease.isCompleted) mediaChannelRelease.complete();
    });
    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
    );
    final mobile = WebViewController();
    final storage = _MemorySecureStorage();
    final client = MissavClient(secureStorage: storage);
    addTearDown(client.dispose);

    await tester.runAsync(() async {
      final connection = await _pumpUntilComplete(
        tester,
        connectMissavBrowserSession(client, mobile: mobile),
      );
      expect(connection.signedIn, isFalse);
      expect(connection.importedSession, isTrue);
      expect(mediaChannelAttempts, 0);

      Future<VideoStream> prepare() =>
          client.prepareMediaStream(_relayVideo, _relayStream);
      final cancelled = expectLater(prepare(), throwsA(isA<MissavException>()));
      await _pumpUntilComplete(tester, mediaChannelStarted.future);
      await _pumpUntilComplete(
        tester,
        client.importVerifiedSession(
          cookieHeader: 'session=replaced',
          userAgent: 'test-browser',
        ),
      );
      await client.discardVerifiedSession(
        expectedGeneration: connection.sessionGeneration,
      );
      expect(storage.cookie, 'session=replaced');
      await _pumpUntilComplete(tester, cancelled);
      expect(await mobile.currentUrl(), client.originHomeUrl);

      platform.mediaChannelDelay = null;
      final routed = await _pumpUntilComplete(tester, prepare());
      expect(Uri.parse(routed.url).host, '127.0.0.1');
      mediaChannelRelease.complete();
      expect((await prepare()).url, routed.url);
      expect(mediaChannelAttempts, 2);
      await client.importVerifiedSession(
        cookieHeader: 'session=replaced',
        userAgent: 'test-browser',
      );
    });
    await tester.pumpAndSettle();
  });

  for (final (trustedPage, accountInMarkup) in [
    (true, false),
    (true, true),
    (false, false),
    (false, true),
  ]) {
    final evidence = accountInMarkup ? 'page markup' : 'runtime state';
    testWidgets(
      trustedPage
          ? 'access check preserves the web sign-in from $evidence before reloading'
          : 'access check ignores $evidence from a foreign page',
      (tester) async {
        final oldPlatform = WebViewPlatform.instance;
        late final _FakeWebViewController sourcePage;
        var homeNavigations = 0;
        WebViewPlatform.instance = _FakeWebViewPlatform(
          Future.value([
            const WebViewCookie(
              name: 'session',
              value: 'verified',
              domain: 'missav.ai',
            ),
          ]),
          initialUrl: trustedPage
              ? 'https://missav.ai/login'
              : 'https://example.invalid/login',
          onLoadRequest: (_) async {
            homeNavigations++;
            sourcePage.htmlDocument = '';
            sourcePage.runtimeUser = null;
          },
        );
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });

        await tester.pumpWidget(
          MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
        );
        final mobile = WebViewController();
        sourcePage = mobile.platform as _FakeWebViewController;
        if (accountInMarkup) {
          sourcePage.htmlDocument =
              '''<html><body x-data='{"user":{"username":"browser-viewer"}}'></body></html>''';
        } else {
          sourcePage.runtimeUser = {'username': 'browser-viewer'};
        }
        final client = MissavClient(secureStorage: _MemorySecureStorage());
        addTearDown(client.dispose);

        Object? connectionError;
        await tester.runAsync(() async {
          final connection = connectMissavBrowserSession(
            client,
            mobile: mobile,
          );
          final outcome = connection.then<Object?>(
            (_) => null,
            onError: (Object error) => error,
          );
          var finished = false;
          final result = outcome.whenComplete(() => finished = true);
          await Future.wait([
            result,
            () async {
              while (!finished) {
                await tester.pump();
                await Future<void>.delayed(Duration.zero);
              }
            }(),
          ]);
          connectionError = await outcome;
        });
        await tester.pumpAndSettle();

        expect(connectionError, isNull);
        expect(homeNavigations, greaterThan(0));
        expect(client.isLoggedIn, trustedPage);
        expect(client.accountName, trustedPage ? 'browser-viewer' : null);
      },
    );
  }

  test('document navigation rejects a locale-home redirect', () async {
    await expectLater(
      navigateMissavDocument(
        Uri.parse('https://missav.ai/cn/open-sample-001'),
        Completer<void>().future,
        navigate: (_) async {},
        read: (_) async => {
          'url': 'https://missav.ai/cn',
          'html': '<main><h1>Home</h1></main>',
        },
        stop: () async {},
      ),
      throwsA(isA<MissavException>()),
    );
  });

  test('saved page navigation recognizes an explicit login redirect', () async {
    await expectLater(
      navigateMissavDocument(
        Uri.parse('https://missav.ai/cn/saved'),
        Completer<void>().future,
        navigate: (_) async {},
        read: (_) async => {
          'url': 'https://missav.ai/cn/login',
          'html': '<main><h1>Login</h1></main>',
        },
        stop: () async {},
      ),
      throwsA(isA<MissavAuthenticationException>()),
    );
  });

  test(
    'saved page navigation rejects another same-origin page with a user',
    () async {
      await expectLater(
        navigateMissavDocument(
          Uri.parse('https://missav.ai/cn/saved'),
          Completer<void>().future,
          navigate: (_) async {},
          read: (_) async => {
            'url': 'https://missav.ai/cn/release',
            'html': '<main><h1>Catalog</h1></main>',
            'runtimeUser': {'username': 'redirected-viewer'},
          },
          stop: () async {},
        ),
        throwsA(isA<MissavException>()),
      );
    },
  );

  testWidgets(
    'a foreign favorites redirect releases the browser retained across a session change',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      WebViewPlatform.instance = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'verified',
            domain: 'missav.ai',
          ),
        ]),
      );
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final mobile = WebViewController();
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);

      await tester.runAsync(() async {
        var finished = false;
        final connection = connectMissavBrowserSession(
          client,
          mobile: mobile,
          checkAccess: false,
        ).whenComplete(() => finished = true);
        await Future.wait([
          connection,
          () async {
            while (!finished) {
              await tester.pump();
              await Future<void>.delayed(Duration.zero);
            }
          }(),
        ]);
        expect(await mobile.currentUrl(), 'https://missav.ai/cn');
        client.selectMirror('https://www.missav9.net');
        final generation = client.sessionGeneration;
        final redirected = WebViewController();
        final redirectedPage = redirected.platform as _FakeWebViewController;
        redirectedPage.favoritesHtmlDocument = _favoritesUserMarkup(
          'redirected-viewer',
        );
        redirectedPage.redirectOnReadUrl = 'https://example.invalid/';

        final rejected = expectLater(
          connectMissavBrowserSession(
            client,
            mobile: redirected,
            requireLogin: true,
          ),
          throwsA(isA<MissavException>()),
        );
        await _pumpUntilComplete(tester, rejected);
        expect(redirectedPage.requestedUrls, [
          client.collectionUrl('favorites'),
        ]);
        expect(await mobile.currentUrl(), 'about:blank');
        expect(client.sessionGeneration, greaterThan(generation));
        expect(client.isLoggedIn, isFalse);
      });
      await tester.pumpAndSettle();
    },
  );

  for (final protectedPageStatus in [200, 401]) {
    testWidgets('guest or rejected favorites preserves the saved session '
        '(status: $protectedPageStatus)', (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      WebViewPlatform.instance = _FakeWebViewPlatform(
        Future.value([
          const WebViewCookie(
            name: 'session',
            value: 'guest',
            domain: 'missav.ai',
          ),
        ]),
      );
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });

      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
      );
      final mobile = WebViewController();
      final sourcePage = mobile.platform as _FakeWebViewController;
      sourcePage.htmlDocument =
          '<html><body x-data="{user: null}"></body></html>';
      sourcePage.responseStatusFor = (url) {
        if (Uri.parse(url).pathSegments.lastOrNull != 'saved') return 200;
        if (protectedPageStatus == 401) {
          sourcePage.htmlDocument =
              '<html><body x-data="{user: {name: \'Stale viewer\'}}"></body></html>';
          sourcePage.visibleSignOut = true;
        }
        return protectedPageStatus;
      };
      final storage = _MemorySecureStorage();
      final client = MissavClient(secureStorage: storage);
      addTearDown(client.dispose);
      await client.importVerifiedSession(
        cookieHeader: 'session=previous',
        userAgent: 'Test browser',
      );
      final generation = client.sessionGeneration;
      final writesBefore = storage.writeCalls;

      await tester.runAsync(() async {
        final connection = connectMissavBrowserSession(
          client,
          mobile: mobile,
          requireLogin: true,
        );
        var finished = false;
        final result = expectLater(
          connection.timeout(const Duration(seconds: 5)),
          throwsA(isA<MissavAuthenticationException>()),
        ).whenComplete(() => finished = true);
        await Future.wait([
          result,
          () async {
            while (!finished) {
              await tester.pump();
              await Future<void>.delayed(Duration.zero);
            }
          }(),
        ]);
      });
      await tester.pumpAndSettle();
      expect(sourcePage.requestedUrls, [client.collectionUrl('favorites')]);
      expect(client.sessionGeneration, generation);
      expect(client.isLoggedIn, isFalse);
      expect(client.hasRestorableSession, isTrue);
      expect(await mobile.currentUrl(), client.collectionUrl('favorites'));
      expect(storage.cookie, 'session=previous');
      expect(storage.writeCalls, writesBefore);
    });
  }

  for (final evidence in [
    'runtime user',
    'interactive Favorites',
    'delayed sign-out',
    'fresh page',
    'unprefixed Favorites redirect',
  ]) {
    testWidgets(
      'login completes on the canonical origin without taking over the mirror '
      '($evidence)',
      (tester) async {
        final needsFreshPage = evidence == 'fresh page';
        final oldPlatform = WebViewPlatform.instance;
        late final _FakeWebViewPlatform platform;
        platform = _FakeWebViewPlatform(
          Future.value([
            const WebViewCookie(
              name: 'session',
              value: 'canonical',
              domain: 'missav.ai',
            ),
          ]),
          initialUrl: 'https://missav.ai/cn',
          onLoadRequest: (params) async {
            final page = platform.lastController!;
            page.htmlDocument =
                '<html><body x-data="{user: null}"></body></html>';
            if (needsFreshPage && page.requestedUrls.length == 2) {
              page.favoritesHtmlDocument = _favoritesUserMarkup(
                'canonical-viewer',
              );
            }
            page.runtimeUser = null;
            page.visibleSignOut = false;
            page.responseStatus = 200;
          },
        );
        WebViewPlatform.instance = platform;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const Scaffold(body: SizedBox()),
          ),
        );
        final context = tester.element(find.byType(Scaffold));
        final storage = _MemorySecureStorage();
        final client = MissavClient(secureStorage: storage);
        addTearDown(client.dispose);
        client.selectMirror('https://www.missav9.net');

        final login = verifyMissavLogin(context, client);
        await tester.pumpAndSettle();
        final sourcePage = platform.lastController!;
        final favorites = client.collectionUrl('favorites');
        expect(await sourcePage.currentUrl(), favorites);
        if (evidence == 'delayed sign-out') {
          sourcePage.showSignOutOnSnapshot = 2;
        } else if (!needsFreshPage) {
          sourcePage.runtimeUser = {'username': 'canonical-viewer'};
        }
        if (evidence == 'unprefixed Favorites redirect') {
          sourcePage.redirectOnReadUrl = '${MissavClient.origin}/saved';
        }
        if (evidence == 'interactive Favorites') {
          sourcePage.documentReadyState = 'interactive';
        }

        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(
          find.text(S.of(context).videoLoginConfirmationFailed),
          findsNothing,
        );
        expect(find.widgetWithText(FilledButton, 'Done'), findsNothing);
        expect(await login, isTrue);
        expect(sourcePage.requestedUrls, [
          favorites,
          if (needsFreshPage) favorites,
        ]);
        expect(client.isLoggedIn, isTrue);
        expect(client.homeUrl, 'https://www.missav9.net/cn');
        expect(storage.cookie, 'session=canonical');
        client.restoreNativeTransport();
        await tester.pumpAndSettle();
        expect(find.byType(WebViewWidget), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'cross-origin login navigation fails immediately',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      final platform = _FakeWebViewPlatform(
        Future.value(const []),
        initialUrl: 'https://missav.ai/cn',
      );
      WebViewPlatform.instance = platform;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);

      final login = verifyMissavLogin(context, client);
      await tester.pumpAndSettle();
      final page = platform.lastController!;
      final decision = page._navigationDelegate!.navigationRequest!(
        const NavigationRequest(url: 'https://missav.ws/cn', isMainFrame: true),
      );
      expect(decision, NavigationDecision.prevent);
      await tester.pump();

      expect(find.text('Login failed'), findsOneWidget);
      final done = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Done'),
      );
      expect(done.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await login, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  final loginFailures = [
    (
      name: 'missing Favorites proof',
      cookie: 'guest-secret',
      favoritesHtml: '<html><body x-data="{user: null}"></body></html>',
      expectedMessage:
          'Could not confirm sign-in from Favorites. Check that you are '
          'signed in on the website, then select Done again.',
      expectedStage: VideoLoginPhase.favoritesConfirmation,
      expectedCategory: 'accountNotConfirmed',
      rawValue: 'guest-secret',
    ),
    (
      name: 'confirmed sign-in without a cookie handoff',
      cookie: null,
      favoritesHtml: _favoritesUserMarkup('handoff-viewer'),
      expectedMessage:
          'Website sign-in was confirmed. The app could not take over the '
          'session. Select Done to try again.',
      expectedStage: VideoLoginPhase.browserHandoff,
      expectedCategory: 'state',
      rawValue: 'handoff-viewer',
    ),
    (
      name: 'confirmed sign-in with a session save error',
      cookie: 'candidate-secret',
      favoritesHtml: _favoritesUserMarkup('candidate-viewer'),
      expectedMessage:
          'Website sign-in was confirmed. The app could not take over the '
          'session. Select Done to try again.',
      expectedStage: VideoLoginPhase.sessionSave,
      expectedCategory: 'platform',
      rawValue: 'storage-error-detail',
    ),
  ];
  for (final (source, failure) in [
    for (final source in ['MissAV', 'Jable'])
      for (final failure in loginFailures)
        if (source != 'Jable' ||
            failure.expectedStage != VideoLoginPhase.sessionSave)
          (source, failure),
  ]) {
    testWidgets(
      '$source Done distinguishes ${failure.name} with a safe stage log',
      (tester) async {
        final oldPlatform = WebViewPlatform.instance;
        final isJable = source == 'Jable';
        final origin = isJable ? JableClient.origin : MissavClient.origin;
        final startUrl = isJable ? '$origin/login/' : '$origin/cn/saved';
        final favoritesUrl = isJable
            ? JableAccount.favoritesUrl
            : '$origin/cn/saved';
        final confirmationFailed =
            failure.expectedStage == VideoLoginPhase.favoritesConfirmation;
        final savingFailed =
            failure.expectedStage == VideoLoginPhase.sessionSave;
        late final _FakeWebViewPlatform platform;
        platform = _FakeWebViewPlatform(
          Future.value([
            if (failure.cookie case final cookie?)
              WebViewCookie(
                name: 'session',
                value: cookie,
                domain: Uri.parse(origin).host,
              ),
          ]),
          initialUrl: startUrl,
          onLoadRequest: (params) async {
            if (params.uri.toString() != favoritesUrl) return;
            if (isJable) {
              platform.lastController!.htmlDocument = confirmationFailed
                  ? '<html><body>Sign in</body></html>'
                  : '<html><body id="list_videos_my_favourite_videos"></body></html>';
            } else {
              platform.lastController!.favoritesHtmlDocument =
                  failure.favoritesHtml;
            }
          },
        );
        WebViewPlatform.instance = platform;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            locale: const Locale('en'),
            localizationsDelegates: S.localizationsDelegates,
            supportedLocales: S.supportedLocales,
            home: const Scaffold(body: SizedBox()),
          ),
        );
        final context = tester.element(find.byType(Scaffold));
        final storage = _MemorySecureStorage();
        if (savingFailed) {
          storage.writeError = PlatformException(
            code: 'write-failed',
            message: failure.rawValue,
          );
        }
        final Future<bool> login;
        final bool Function() isLoggedIn;
        if (isJable) {
          final client = JableClient(secureStorage: storage);
          addTearDown(client.dispose);
          isLoggedIn = () => client.account.isLoggedIn;
          login = verifyJableAccess(
            context,
            client,
            sourceUrl: startUrl,
            requireLogin: true,
          );
        } else {
          final client = MissavClient(secureStorage: storage);
          addTearDown(client.dispose);
          isLoggedIn = () => client.isLoggedIn;
          login = verifyMissavLogin(context, client);
        }
        await tester.pumpAndSettle();
        final page = platform.lastController!;
        expect(await page.currentUrl(), startUrl);

        LogService.instance.clear();
        await tester.tap(find.widgetWithText(FilledButton, 'Done'));
        await tester.pump();
        await tester.pumpAndSettle();

        final s = S.of(context);
        final expectedMessage = confirmationFailed
            ? s.videoLoginConfirmationFailed
            : s.videoLoginHandoffFailed;
        expect(expectedMessage, failure.expectedMessage);
        expect(find.text(expectedMessage), findsOneWidget);
        expect(find.text('Login failed'), findsNothing);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Done'))
              .onPressed,
          isNotNull,
        );
        if (!savingFailed) {
          expect(
            await page.currentUrl(),
            isJable && confirmationFailed ? startUrl : favoritesUrl,
          );
        }
        expect(isLoggedIn(), isFalse);
        expect(storage.writeCalls, savingFailed ? 1 : 0);
        expect(storage.values, isEmpty);

        final failureLogs = LogService.instance.logs
            .map((entry) => entry.message)
            .where((line) => line.startsWith('$source login failed:'))
            .toList();
        expect(failureLogs, hasLength(1));
        expect(
          failureLogs.single,
          matches(
            RegExp(
              '^$source login failed: '
              'stage=${failure.expectedStage.name} '
              'category=${failure.expectedCategory} '
              r'elapsedMs=\d+$',
            ),
          ),
        );
        expect(failureLogs.single, isNot(contains(failure.rawValue)));
        expect(failureLogs.single, isNot(contains('session=')));

        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(await login, isFalse);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final cancel in [false, true]) {
    testWidgets(
      cancel
          ? 'cancelling during browser handoff preserves the stored session'
          : 'failed browser handoff preserves the stored session',
      (tester) async {
        final oldPlatform = WebViewPlatform.instance;
        late final _FakeWebViewPlatform platform;
        platform = _FakeWebViewPlatform(
          Future.value([
            const WebViewCookie(
              name: 'session',
              value: 'browser',
              domain: 'missav.ai',
            ),
          ]),
          initialUrl: 'https://missav.ai/cn',
          onLoadRequest: (params) async {
            if (params.uri.pathSegments.lastOrNull == 'saved') {
              platform.lastController!.favoritesHtmlDocument =
                  _favoritesUserMarkup('browser-viewer');
            }
          },
        );
        WebViewPlatform.instance = platform;
        addTearDown(() {
          if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
        });
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(
          MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
        );
        final mobile = WebViewController();
        final storage = _MemorySecureStorage();
        final client = MissavClient(secureStorage: storage);
        addTearDown(client.dispose);
        await client.importVerifiedSession(
          cookieHeader: 'session=stored',
          userAgent: 'stored-agent',
        );
        final generation = client.sessionGeneration;
        final storedValues = Map<String, String>.of(storage.values);
        final writesBefore = storage.writeCalls;
        final retainRelease = Completer<void>();
        final cancelSignal = Completer<void>();
        (int, String?)? sessionAtHandoff;

        Future<void> retain() async {
          sessionAtHandoff = (storage.writeCalls, storage.cookie);
          if (!cancel) throw StateError('handoff failed');
          await retainRelease.future;
        }

        final outcome = expectLater(
          connectMissavBrowserSession(
            client,
            mobile: mobile,
            cancelSignal: cancel ? cancelSignal : null,
            requireLogin: true,
            retainMobileBrowser: retain,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains(cancel ? 'cancelled' : 'handoff failed'),
            ),
          ),
        );
        await tester.pump(Duration.zero);
        expect(sessionAtHandoff, (writesBefore, 'session=stored'));
        if (cancel) {
          expect(storage.writeCalls, writesBefore);
          cancelSignal.complete();
          retainRelease.complete();
        }
        await tester.pump(Duration.zero);
        await outcome;
        expect(client.sessionGeneration, generation);
        expect(client.hasRestorableSession, isTrue);
        expect(client.isLoggedIn, isFalse);
        expect(storage.values, equals(storedValues));
        expect(storage.writeCalls, writesBefore);
        expect(storage.cookie, 'session=stored');
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'account verification and access checks ignore mirror source URLs',
    (tester) async {
      final oldPlatform = WebViewPlatform.instance;
      addTearDown(() {
        if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
      });
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          locale: const Locale('en'),
          localizationsDelegates: S.localizationsDelegates,
          supportedLocales: S.supportedLocales,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      final context = tester.element(find.byType(Scaffold));
      final client = MissavClient(secureStorage: _MemorySecureStorage());
      addTearDown(client.dispose);

      final accountPlatform = _FakeWebViewPlatform(
        Future.value(const []),
        initialUrl: 'https://missav.ai/cn',
      );
      WebViewPlatform.instance = accountPlatform;
      final account = verifyMissavAccount(
        context,
        client,
        sourceUrl: 'https://missav.ws/cn',
      );
      await tester.pumpAndSettle();
      expect(
        await accountPlatform.lastController!.currentUrl(),
        client.collectionUrl('favorites'),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await account, (verified: false, signedIn: false));

      final accessPlatform = _FakeWebViewPlatform(
        Future.value(const []),
        initialUrl: 'https://missav.ai/cn',
      );
      WebViewPlatform.instance = accessPlatform;
      final access = verifyMissavAccess(
        context,
        client,
        sourceUrl: 'https://missav.ws/cn',
      );
      await tester.pumpAndSettle();
      expect(
        await accessPlatform.lastController!.currentUrl(),
        'https://missav.ai/cn',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await access, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('a selected mirror does not redirect the sign-in browser', (
    tester,
  ) async {
    final oldPlatform = WebViewPlatform.instance;
    WebViewPlatform.instance = _FakeWebViewPlatform(
      Future.value([
        const WebViewCookie(
          name: 'session',
          value: 'guest',
          domain: 'missav.ai',
        ),
      ]),
    );
    addTearDown(() {
      if (oldPlatform != null) WebViewPlatform.instance = oldPlatform;
    });

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const SizedBox()),
    );
    final mobile = WebViewController();
    final sourcePage = mobile.platform as _FakeWebViewController;
    sourcePage.htmlDocument =
        '<html><body x-data="{user: null}"></body></html>';
    final client = MissavClient(secureStorage: _MemorySecureStorage())
      ..selectMirror('https://www.missav9.net');
    addTearDown(client.dispose);
    expect(client.homeUrl, 'https://www.missav9.net/cn');

    await tester.runAsync(() async {
      final connection = connectMissavBrowserSession(
        client,
        mobile: mobile,
        requireLogin: true,
      );
      var finished = false;
      final result = expectLater(
        connection.timeout(const Duration(seconds: 5)),
        throwsA(isA<MissavAuthenticationException>()),
      ).whenComplete(() => finished = true);
      await Future.wait([
        result,
        () async {
          while (!finished) {
            await tester.pump();
            await Future<void>.delayed(Duration.zero);
          }
        }(),
      ]);
    });
    await tester.pumpAndSettle();
    expect(await mobile.currentUrl(), client.collectionUrl('favorites'));
    expect(client.homeUrl, 'https://www.missav9.net/cn');
  });
}

const _relayVideo = VideoItem(
  id: 'open-sample-001',
  title: 'Sample',
  pageUrl: 'https://missav.ai/cn/open-sample-001',
);

const _relayStream = VideoStream(
  label: 'Source',
  url: 'https://media.example.net/master.m3u8',
  headers: {'Referer': 'https://missav.ai/'},
  isHls: true,
);

String _favoritesUserMarkup(String username) =>
    '''<html><body x-data='{"user":{"username":"$username"}}'></body></html>''';

bool _isFavoritesDocumentUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.origin == MissavClient.origin &&
      uri.pathSegments.lastOrNull == 'saved';
}

Future<T> _pumpUntilComplete<T>(
  WidgetTester tester,
  Future<T> operation,
) async {
  var finished = false;
  final result = operation
      .timeout(const Duration(seconds: 5))
      .whenComplete(() => finished = true);
  await Future.wait<void>([
    result.then<void>((_) {}),
    () async {
      while (!finished) {
        await tester.pump();
        await Future<void>.delayed(Duration.zero);
      }
    }(),
  ]);
  return result;
}

class _DesktopBrowser extends Fake implements Webview {
  final state = ValueNotifier(
    const WebviewNavigationState(url: 'https://missav.ai/cn', isLoading: true),
  );
  final stopRequested = Completer<void>();
  final closed = Completer<void>();

  @override
  ValueListenable<WebviewNavigationState> get navigationState => state;

  @override
  Future<void> get onClose => closed.future;

  @override
  Future<void> stop() async => stopRequested.complete();
}

class _FakeWebViewPlatform extends WebViewPlatform {
  _FakeWebViewPlatform(
    this.cookies, {
    this.initialUrl = 'https://missav.ai/cn',
    this.onLoadRequest,
    this.onLoadHtml,
    this.loadRequestCompletion,
    this.failMediaChannel = false,
    this.mediaChannelDelay,
    this.onMediaChannel,
  });

  final Future<List<WebViewCookie>> cookies;
  final String? initialUrl;
  final Future<void> Function(LoadRequestParams params)? onLoadRequest;
  final Future<void> Function()? onLoadHtml;
  final Future<void>? loadRequestCompletion;
  bool failMediaChannel;
  Future<void>? mediaChannelDelay;
  final void Function()? onMediaChannel;
  final cookiesRequested = Completer<void>();
  _FakeWebViewController? lastController;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    final controller = _FakeWebViewController(
      params,
      initialUrl: initialUrl,
      onLoadRequest: onLoadRequest,
      onLoadHtml: onLoadHtml,
      loadRequestCompletion: loadRequestCompletion,
      failMediaChannel: failMediaChannel,
      mediaChannelDelay: mediaChannelDelay,
      onMediaChannel: onMediaChannel,
    );
    lastController = controller;
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakeNavigationDelegate(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _FakeCookieManager(params, cookies, cookiesRequested);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakeWebViewWidget(params);
}

class _FakeWebViewWidget extends PlatformWebViewWidget {
  _FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _FakeWebViewController extends PlatformWebViewController {
  _FakeWebViewController(
    super.params, {
    required String? initialUrl,
    this.onLoadRequest,
    this.onLoadHtml,
    this.loadRequestCompletion,
    this.failMediaChannel = false,
    this.mediaChannelDelay,
    this.onMediaChannel,
  }) : _url = initialUrl,
       documentUrl = initialUrl,
       super.implementation();

  String? _url;
  String? documentUrl;
  String htmlDocument = '';
  String? favoritesHtmlDocument;
  String? redirectOnReadUrl;
  Map<String, Object?>? runtimeUser;
  bool visibleSignOut = false;
  int? showSignOutOnSnapshot;
  int _snapshotCount = 0;
  bool hasDocumentElement = true;
  String? documentElementId;
  String documentReadyState = 'complete';
  int loadHtmlStringCalls = 0;
  bool documentNavigationPending = false;
  bool cloudflareChallenge = false;
  int? responseStatus;
  int? Function(String url)? responseStatusFor;
  int networkNavigations = 0;
  final requestedUrls = <String>[];
  final htmlLoadStarted = Completer<void>();
  final verificationReadyCheckStarted = Completer<void>();
  Completer<void>? _nextDocumentReadinessCheck;
  _FakeNavigationDelegate? _navigationDelegate;
  final Future<void> Function(LoadRequestParams params)? onLoadRequest;
  final Future<void> Function()? onLoadHtml;
  final Future<void>? loadRequestCompletion;
  final bool failMediaChannel;
  final Future<void>? mediaChannelDelay;
  final void Function()? onMediaChannel;

  Future<void> nextDocumentReadinessCheck() {
    final check = Completer<void>();
    _nextDocumentReadinessCheck = check;
    return check.future;
  }

  @override
  Future<String?> currentUrl() async => _url;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {
    _navigationDelegate = handler as _FakeNavigationDelegate;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    networkNavigations++;
    final url = params.uri.toString();
    requestedUrls.add(url);
    final decision = await _navigationDelegate?.navigationRequest?.call(
      NavigationRequest(url: url, isMainFrame: true),
    );
    if (decision != NavigationDecision.prevent) {
      void finishNavigation() {
        _url = url;
        documentUrl = url;
        hasDocumentElement = true;
        documentElementId = null;
        documentReadyState = 'complete';
        documentNavigationPending = false;
        cloudflareChallenge = false;
        _navigationDelegate?.pageFinished?.call(url);
      }

      final loading = onLoadRequest?.call(params);
      if (loading == null) {
        finishNavigation();
      } else {
        unawaited(loading.then((_) => finishNavigation()));
      }
    }
    await loadRequestCompletion;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    loadHtmlStringCalls++;
    if (!htmlLoadStarted.isCompleted) htmlLoadStarted.complete();
    unawaited(() async {
      await onLoadHtml?.call();
      _url = 'about:blank';
      documentUrl = baseUrl;
      htmlDocument = html;
      hasDocumentElement = true;
      documentReadyState = 'complete';
      documentNavigationPending = false;
      cloudflareChallenge = false;
      documentElementId = html.contains('kikoflu-browser-bridge')
          ? 'kikoflu-browser-bridge'
          : null;
      _navigationDelegate?.pageFinished?.call('about:blank');
    }());
  }

  @override
  Future<void> addJavaScriptChannel(
    JavaScriptChannelParams javaScriptChannelParams,
  ) async {
    if (javaScriptChannelParams.name ==
        MissavBrowserMediaTransport.channelName) {
      onMediaChannel?.call();
      await mediaChannelDelay;
      if (failMediaChannel) {
        throw StateError('Media relay unavailable.');
      }
    }
  }

  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {
    if (javaScript.contains('window.__kikofluMissavNavigationPending = true')) {
      documentNavigationPending = true;
    }
  }

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    if (javaScript == 'document.documentElement?.outerHTML ?? ""') {
      return htmlDocument;
    }
    if (javaScript.contains('const root = document.documentElement;')) {
      _snapshotCount++;
      var url = documentUrl ?? _url ?? 'https://missav.ai/cn';
      final favorites = _isFavoritesDocumentUrl(url);
      if (redirectOnReadUrl case final redirect? when favorites) {
        redirectOnReadUrl = null;
        _url = redirect;
        documentUrl = redirect;
        url = redirect;
      }
      final status = responseStatusFor?.call(url) ?? responseStatus;
      final favoritesHtml = favorites ? favoritesHtmlDocument : null;
      final document = <String, Object?>{
        'url': url,
        'html':
            favoritesHtml ??
            (htmlDocument.isEmpty
                ? '<html><body x-data="{user: null}"></body></html>'
                : htmlDocument),
        if (status != null) 'responseStatus': status,
        'menuSignOut':
            visibleSignOut ||
            (showSignOutOnSnapshot != null &&
                _snapshotCount >= showSignOutOnSnapshot!),
        if (cloudflareChallenge) 'verificationRequired': true,
      };
      if (runtimeUser != null && favoritesHtml == null) {
        document['runtimeUser'] = runtimeUser;
      }
      return document;
    }
    if (javaScript.contains('__kikofluMissavNavigationPending')) {
      if (!verificationReadyCheckStarted.isCompleted) {
        verificationReadyCheckStarted.complete();
      }
      final check = _nextDocumentReadinessCheck;
      if (check != null && !check.isCompleted) check.complete();
      if (cloudflareChallenge && javaScript.contains("'challenge'")) {
        return 'challenge';
      }
      return isMissavVerificationUrl(documentUrl ?? '') &&
          (javaScript.contains("document.readyState === 'complete'")
              ? documentReadyState == 'complete'
              : documentReadyState != 'loading') &&
          hasDocumentElement &&
          documentElementId != 'kikoflu-browser-bridge' &&
          !documentNavigationPending &&
          !cloudflareChallenge;
    }
    if (javaScript.contains('location.origin')) {
      final source = isMissavVerificationUrl(documentUrl ?? '');
      return source &&
          (!javaScript.contains('kikoflu-browser-bridge') ||
              (hasDocumentElement &&
                  documentElementId == 'kikoflu-browser-bridge'));
    }
    if (javaScript.contains('document.readyState')) {
      if (!verificationReadyCheckStarted.isCompleted) {
        verificationReadyCheckStarted.complete();
      }
      return (!javaScript.contains('!!document.documentElement') ||
              hasDocumentElement) &&
          (!javaScript.contains("document.readyState === 'complete'") ||
              documentReadyState == 'complete') &&
          (!javaScript.contains(
                "document.documentElement.id !== 'kikoflu-browser-bridge'",
              ) ||
              documentElementId != 'kikoflu-browser-bridge');
    }
    return true;
  }

  @override
  Future<String?> getUserAgent() async => 'test-browser';
}

class _FakeNavigationDelegate extends PlatformNavigationDelegate {
  _FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? navigationRequest;
  PageEventCallback? pageFinished;
  WebResourceErrorCallback? webResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    navigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    pageFinished = onPageFinished;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    webResourceError = onWebResourceError;
  }
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager(super.params, this.cookies, this.cookiesRequested)
    : super.implementation();

  final Future<List<WebViewCookie>> cookies;
  final Completer<void> cookiesRequested;

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) {
    if (!cookiesRequested.isCompleted) cookiesRequested.complete();
    return cookies;
  }
}

class _MemorySecureStorage implements FlutterSecureStorage {
  int writeCalls = 0;
  PlatformException? writeError;
  final values = <String, String>{};

  String? get cookie => values['iroru.missav_session_cookie'];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    if (invocation.memberName == #read) {
      return Future<String?>.value(key == null ? null : values[key]);
    }
    if (invocation.memberName == #write) {
      writeCalls++;
      if (writeError case final error?) return Future<void>.error(error);
      final value = invocation.namedArguments[#value] as String?;
      if (key != null) {
        if (value == null) {
          values.remove(key);
        } else {
          values[key] = value;
        }
      }
      return Future<void>.value();
    }
    if (invocation.memberName == #delete) {
      if (key != null) values.remove(key);
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

WebviewCookie _cookie(
  String name, {
  String domain = 'missav.ai',
  String path = '/',
  DateTime? expires,
  bool httpOnly = false,
  bool sessionOnly = false,
}) => WebviewCookie(
  name: name,
  value: 'value',
  domain: domain,
  path: path,
  expires: expires,
  secure: true,
  httpOnly: httpOnly,
  sessionOnly: sessionOnly,
);
