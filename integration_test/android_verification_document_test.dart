import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:iroru/src/videos/missav_client.dart';
import 'package:iroru/src/videos/missav_verification.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  for (final guest in [false, true]) {
    testWidgets(
      'Android confirms a collapsed favorites menu only for its account (guest: $guest)',
      (tester) async {
        final browser = WebViewController();
        await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
        final loaded = Completer<void>();
        await browser.setNavigationDelegate(
          NavigationDelegate(
            onPageFinished: (_) {
              if (!loaded.isCompleted) loaded.complete();
            },
          ),
        );
        await tester.pumpWidget(
          MaterialApp(home: WebViewWidget(controller: browser)),
        );
        final uri = Uri.parse('https://missav.ai/cn/saved');
        final markup = await navigateMissavDocument(
          uri,
          Completer<void>().future,
          navigate: (_) async {
            await browser.loadHtmlString('''<nav x-data="{open:false}">
                <button @click="open = !open">Menu</button>
                <div x-show="open" style="display:none">
                  <div ${guest ? 'x-show="user" style="display:none"' : ''}>
                    <a href="/logout">Sign out</a>
                  </div>
                </div>
              </nav>''', baseUrl: uri.toString());
            await loaded.future.timeout(const Duration(seconds: 15));
          },
          read: browser.runJavaScriptReturningResult,
          stop: () => browser.runJavaScript('window.stop();'),
        );
        expect(
          MissavClient.readFavoritesAccountFromMarkup(markup, uri) != null,
          !guest,
        );
      },
      skip: !Platform.isAndroid,
    );
  }

  testWidgets(
    'Android reads a verified document through the real WebView bridge',
    (tester) async {
      final browser = WebViewController();
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      final loaded = Completer<void>();
      await browser.setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!loaded.isCompleted) loaded.complete();
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WebViewWidget(controller: browser)),
        ),
      );

      try {
        final uri = Uri.parse('https://missav.ai/cn');
        final document = await navigateMissavDocument(
          uri,
          Completer<void>().future,
          navigate: (_) async {
            await browser.loadHtmlString(
              '<!doctype html><html><head><title>Verified fixture</title>'
              '</head><body><a href="/logout">退出登录</a>'
              '<main>Verified account fixture</main></body></html>',
              baseUrl: uri.toString(),
            );
            await loaded.future.timeout(const Duration(seconds: 15));
          },
          read: browser.runJavaScriptReturningResult,
          stop: () => browser.runJavaScript('window.stop();'),
        );

        expect(document, contains('Verified account fixture'));
        expect(document, contains('退出登录'));
        await browser.runJavaScript('''
window.kikofluSourceFixture = true;
document.cookie = 'kikoflu_bridge_fixture=retained; Path=/; Secure; SameSite=Lax';
localStorage.setItem('kikoflu_bridge_fixture', 'retained');
''');
        await parkMissavMobileBrowser(browser);
        expect(await missavMobileSourceUrl(browser), 'https://missav.ai/');
        expect(
          await browser.runJavaScriptReturningResult('''
typeof window.kikofluSourceFixture === 'undefined' &&
document.cookie.includes('kikoflu_bridge_fixture=retained') &&
localStorage.getItem('kikoflu_bridge_fixture') === 'retained'
'''),
          isTrue,
        );
      } finally {
        await browser.runJavaScript('''
document.cookie = 'kikoflu_bridge_fixture=; Path=/; Secure; Max-Age=0';
localStorage.removeItem('kikoflu_bridge_fixture');
''');
        await browser.runJavaScript('window.stop();');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    skip: !Platform.isAndroid,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
