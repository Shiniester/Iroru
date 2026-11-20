import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/proxy_config.dart';
import '../services/remote_asset_cache.dart';
import 'missav_browser_adapter.dart';
import 'missav_mirrors.dart';
import 'video_mirror_selection.dart';
import 'video_models.dart';
import 'video_source_client.dart';

typedef _ContentPage = ({
  Document document,
  Uri uri,
  String? title,
  List<VideoStream> streams,
});

class MissavClient extends ChangeNotifier implements VideoSourceClient {
  MissavClient({
    Dio? dio,
    Dio? metadataDio,
    FlutterSecureStorage? secureStorage,
    List<String>? contentHosts,
    this.restoreSavedSession,
  }) : _secureStorage =
           secureStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           ),
       _dio = dio ?? Dio(_defaultOptions()),
       _contentHosts = List.unmodifiable(contentHosts ?? const <String>[]),
       _metadataDio =
           metadataDio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 5),
               receiveTimeout: const Duration(seconds: 5),
               sendTimeout: const Duration(seconds: 5),
               followRedirects: false,
             ),
           ) {
    if (dio == null) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    if (metadataDio == null) {
      _metadataDio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () =>
            HttpClient()..findProxy = ProxyConfig.findProxyFor,
      );
    }
    _nativeAdapter = _dio.httpClientAdapter;
  }

  static const origin = 'https://missav.ai';
  static final _sourceDomains = {
    'missav.ai',
    'missav.ws',
    'missav.live',
    'thisav66.com',
    for (final mirror in missavMirrors) missavMirrorDomain(mirror.host),
  };
  static final _mirrorHosts = {
    for (final mirror in missavMirrors) missavMirrorDomain(mirror.host),
  };
  static const _officialHosts = missavOfficialHosts;
  static const _cookieKey = 'iroru.missav_session_cookie';
  static const _sessionRecordKey = 'iroru.missav_verified_session';
  static String get _defaultUserAgent {
    if (Platform.isAndroid) {
      return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/149.0.0.0 Mobile Safari/537.36';
    }
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 '
          'Mobile/15E148 Safari/604.1';
    }
    if (Platform.isMacOS) {
      return 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/149.0.0.0 Safari/537.36';
    }
    if (Platform.isLinux) {
      return 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36';
    }
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/149.0.0.0 Safari/537.36';
  }

  static const _pageLimit = 5;
  static const _contentPageTimeout = Duration(seconds: 12);
  static const _contentHostTimeout = Duration(seconds: 4);
  static const _contentBackupDelay = Duration(milliseconds: 1500);
  // MissAV publishes this frontend token for Recombee catalog requests.
  static const _metadataPublicToken =
      'Ikkg568nlM51RHvldlPvc2GzZPE9R4XGzaH9Qj4zK9npbbbTly1gj9K4mgRn0QlV';
  // These categories belong to MissAV's uncensored navigation section.
  static const _uncensoredTypes = {
    'uncensored',
    'uncensored-leak',
    'fc2',
    'heyzo',
    'tokyo-hot',
    '1pondo',
    'caribbeancom',
    'caribbeancompr',
    '10musume',
    'pacopacomama',
    'gachinco',
    'xxx-av',
    'married-scent',
    'naughty4610',
    'naughty0930',
  };

  final FlutterSecureStorage _secureStorage;
  final Future<void> Function(MissavClient client, int expectedGeneration)?
  restoreSavedSession;
  final Dio _dio;
  final Dio _metadataDio;
  final List<String> _contentHosts;
  late final HttpClientAdapter _nativeAdapter;
  Dio? _browserDio;
  HttpClientAdapter? get _browserAdapter => _browserDio?.httpClientAdapter;
  FutureOr<Uri> Function(Uri)? _mediaRoute;
  Future<void> Function()? _resetMedia;
  MissavVerificationRequiredException? _mediaVerification;
  MissavVerificationRequiredException? get mediaVerification =>
      _mediaVerification;
  bool _useBrowserForContent = false;
  int _sessionGeneration = 0;
  CancelToken _sessionCancelToken = CancelToken();
  final List<CancelToken> _browseCancelTokens = [];
  Future<void> _pendingSessionWrite = Future.value();
  Future<void>? _initializing;
  Future<bool>? _accountRestore;
  SharedPreferences? _contentPreferences;
  bool _initialized = false;
  _MissavCookies _cookies = const _MissavCookies();
  String? _sessionHost;
  bool _confirmedGuest = false;
  String _userAgent = _defaultUserAgent;
  String _baseUrl = origin;
  bool _contentHostReady = false;
  final _mirrorSelection = VideoMirrorSelection(
    missavMirrorForBaseUrl,
    missavLastGoodHostKey,
  );
  String? get _preferredMirror => _mirrorSelection.preferred;
  String? get _automaticProbeHost =>
      _useBrowserForContent ? null : _mirrorSelection.automaticProbe;
  Timer? _mirrorProbeTimer;
  CancelToken? _mirrorProbeToken;
  String? _accountName;
  String _locale = 'cn';
  String _homeUrl = '$origin/cn';
  bool _isLoggedIn = false;
  bool _disposed = false;
  String? _recommendationUserId;
  String? _recommendationScenario;
  final Map<String, _MissavSearchState> _searches = {};

  bool get isLoggedIn => _isLoggedIn;
  bool get hasRestorableSession =>
      _cookies.header != null || _browserAdapter != null;
  @override
  String get sourceKey => 'missav';
  int get sessionGeneration => _sessionGeneration;
  String? get accountName => _accountName;
  String get activeMirrorHost => Uri.parse(_baseUrl).host;
  bool get usesAutomaticMirror => _preferredMirror == null;
  static const accountHosts = missavOfficialBaseUrls;
  String _accountBaseUrl = accountHosts.first;
  String get accountHostUrl => _accountBaseUrl;
  String get _activeAccountBaseUrl =>
      _sessionHost ?? (_browserAdapter != null ? origin : _accountBaseUrl);
  @override
  String get homeUrl => _homeUrl;

  String get originHomeUrl =>
      '$origin${_localePrefix.isEmpty ? '/' : _localePrefix}';

  @override
  String get defaultCatalogUrl => '$homeUrl/release';

  void _notifyContentHostChanged() {
    if (!_disposed) notifyListeners();
  }

  @override
  List<VideoSearchFilterKind> get searchFilterKinds =>
      VideoSearchFilterKind.values;

  @override
  bool setLocale(String languageTag) {
    final parts = languageTag.replaceAll('_', '-').toLowerCase().split('-');
    final locale = switch (parts.first) {
      'zh' =>
        parts.any(const {'hant', 'tw', 'hk', 'mo'}.contains) ? 'zh' : 'cn',
      'ja' => 'ja',
      _ => 'en',
    };
    if (_locale == locale) return false;
    _locale = locale;
    _searches.clear();
    _homeUrl = '$_baseUrl${_localePrefix.isEmpty ? '/' : _localePrefix}';
    return true;
  }

  String collectionUrl(String kind) {
    final path = switch (kind) {
      'favorites' => 'saved',
      'actorFavorites' => 'saved/actresses',
      'playlists' => 'playlists',
      'history' => 'history',
      _ => throw ArgumentError.value(kind, 'kind'),
    };
    return '$origin$_localePrefix/$path';
  }

  void useVerifiedBrowserTransport(
    HttpClientAdapter adapter, {
    FutureOr<Uri> Function(Uri)? mediaRoute,
    Future<void> Function()? resetMedia,
  }) {
    if (_disposed) return;
    if (identical(adapter, _nativeAdapter)) {
      restoreNativeTransport();
      return;
    }
    if (identical(adapter, _browserAdapter)) {
      if (mediaRoute != null) _mediaRoute = mediaRoute;
      if (resetMedia != null) _resetMedia = resetMedia;
      _mediaVerification = null;
      return;
    }

    final previousBrowserDio = _browserDio;
    _advanceSessionGeneration();
    _browserDio = _dio.clone(httpClientAdapter: adapter);
    _mediaRoute = mediaRoute;
    _resetMedia = resetMedia;
    _mediaVerification = null;
    _useBrowserForContent = true;
    _baseUrl = origin;
    _homeUrl = '$origin$_localePrefix';
    previousBrowserDio?.close(force: true);
    notifyListeners();
  }

  void restoreNativeTransport({HttpClientAdapter? expectedAdapter}) {
    if (_disposed ||
        (expectedAdapter != null &&
            !identical(expectedAdapter, _browserAdapter))) {
      return;
    }
    _advanceSessionGeneration();
    final browserDio = _browserDio;
    _browserDio = null;
    _useBrowserForContent = false;
    _contentHostReady = false;
    _mediaRoute = null;
    _resetMedia = null;
    _mediaVerification = null;
    browserDio?.close(force: true);
    notifyListeners();
  }

  Future<VideoStream> prepareMediaStream(VideoItem video, VideoStream stream) =>
      prepareMediaStreamWithCancellation(
        video,
        stream,
        RemoteAssetCancellation(),
      );

  Future<VideoStream> prepareMediaStreamWithCancellation(
    VideoItem video,
    VideoStream stream,
    RemoteAssetCancellation cancellation,
  ) async {
    final route = _mediaRoute;
    final browser = _browserAdapter;
    final page = Uri.tryParse(video.pageUrl);
    if (route == null ||
        page == null ||
        page.origin != origin ||
        browser is MissavBrowserAdapter && browser.isClosed) {
      return stream;
    }
    final generation = _sessionGeneration;
    final routed = await Future.any<Uri>([
      Future<Uri>.sync(() => route(Uri.parse(stream.url))),
      cancellation.whenCancelled.then<Uri>(
        (_) =>
            throw const MissavException('MissAV media preparation cancelled.'),
      ),
    ]);
    _checkGeneration(generation, page);
    return VideoStream(
      label: stream.label,
      url: '$routed',
      isHls: stream.isHls,
    );
  }

  void reportMediaVerification(Uri uri) {
    _mediaVerification = MissavVerificationRequiredException(
      sourceUrl: uri.toString(),
    );
    if (!_disposed) notifyListeners();
  }

  void selectMirror(String? baseUrl) {
    if (_disposed) return;
    final mirror = missavMirrorForBaseUrl(baseUrl);
    _advanceSessionGeneration();
    _useBrowserForContent = false;
    _mirrorSelection.select(mirror);
    _contentHostReady = true;
    if (mirror != null) {
      _baseUrl = mirror.baseUrl;
      _homeUrl = '${mirror.baseUrl}$_localePrefix';
    } else {
      _baseUrl =
          _mirrorSelection.initial ?? _contentHosts.firstOrNull ?? origin;
      _homeUrl = '$_baseUrl$_localePrefix';
    }
    notifyListeners();
  }

  void resumeContentBrowsing() => selectMirror(_preferredMirror);

  Future<void> selectAccountHost(String baseUrl) async {
    if (_disposed || !accountHosts.contains(baseUrl)) return;
    if (_accountBaseUrl != baseUrl) {
      _accountBaseUrl = baseUrl;
      notifyListeners();
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(missavAccountBaseUrlKey, baseUrl);
    } catch (_) {
      // Keep the in-memory choice when preferences are unavailable.
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await (_initializing ??= _loadSession());
  }

  Future<void> _prepareOnlineAccess() async {
    await initialize();
    final browser = _browserAdapter;
    if (browser is MissavBrowserAdapter && browser.isClosed) {
      restoreNativeTransport();
    }
    if (_useBrowserForContent) return;
    if (_contentHostReady) return;
    _baseUrl = _mirrorSelection.initial ?? _contentHosts.firstOrNull ?? origin;
    _homeUrl = '$_baseUrl$_localePrefix';
    _contentHostReady = true;
  }

  bool get _canProbeMirrors =>
      _initialized &&
      !_disposed &&
      !_mirrorSelection.probeFinished &&
      !_isLoggedIn &&
      (!hasRestorableSession || _confirmedGuest) &&
      !_useBrowserForContent &&
      _preferredMirror == null;

  void scheduleBackgroundMirrorProbe() {
    if (!_canProbeMirrors || _mirrorProbeToken != null) return;
    _mirrorProbeTimer ??= Timer(const Duration(seconds: 1), () {
      _mirrorProbeTimer = null;
      if (_canProbeMirrors) unawaited(_probeContentHosts());
    });
  }

  void cancelBackgroundMirrorProbe() {
    _mirrorProbeTimer?.cancel();
    _mirrorProbeTimer = null;
    _mirrorProbeToken?.cancel();
    _mirrorProbeToken = null;
  }

  Future<void> _probeContentHosts() async {
    final mirrors = _mirrorSelection.probeCandidates(_contentHosts);
    if (mirrors.isEmpty) return;
    final token = _mirrorProbeToken = CancelToken();
    try {
      final results = await MissavMirrorProber(
        dio: _dio,
        timeout: _contentHostTimeout,
      ).probeAll(mirrors, cancelToken: token, concurrency: 1);
      if (!identical(_mirrorProbeToken, token) || !_canProbeMirrors) return;
      _mirrorSelection.acceptProbeResults(results);
    } catch (_) {
      return;
    } finally {
      if (identical(_mirrorProbeToken, token)) _mirrorProbeToken = null;
    }
  }

  Future<void> _persistContentHost(String key, String? baseUrl) async {
    try {
      await _contentPreferences?.setString(key, baseUrl ?? '');
    } catch (_) {
      // A preference write failure must not fail the page load.
    }
  }

  void _checkContentRequest(
    Uri uri,
    int generation,
    String locale,
    CancelToken cancelToken,
  ) {
    _checkGeneration(generation, uri);
    if (cancelToken.cancelError case final error?) throw error;
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
  }

  Future<void> _loadSession() async {
    final generation = _sessionGeneration;
    String? savedAccountHost;
    try {
      try {
        final preferences = _contentPreferences =
            await SharedPreferences.getInstance();
        final savedMirror = preferences.getString(missavMirrorBaseUrlKey);
        final mirror = missavMirrorForBaseUrl(savedMirror);
        if (generation == _sessionGeneration && !_disposed) {
          _mirrorSelection.restore(preferences, mirror);
          final accountHost = preferences.getString(missavAccountBaseUrlKey);
          if (accountHosts.contains(accountHost)) {
            savedAccountHost = accountHost;
            _accountBaseUrl = accountHost!;
          }
          if (!_contentHostReady) {
            final base = _mirrorSelection.initial;
            if (base != null) {
              _baseUrl = base;
              _homeUrl = '$base$_localePrefix';
            }
          }
        }
        if (savedMirror != null && savedMirror.isNotEmpty && mirror == null) {
          await preferences.setString(missavMirrorBaseUrlKey, '');
        }
      } catch (_) {
        // A missing preference store leaves automatic mirror selection on.
      }
      final record = await _secureStorage.read(key: _sessionRecordKey);
      final session = _decodeStoredSession(record);
      final cookies =
          session?.cookies ??
          _MissavCookies.fromHeader(await _secureStorage.read(key: _cookieKey));
      if (generation == _sessionGeneration && !_disposed) {
        _cookies = cookies;
        _sessionHost = cookies.header == null
            ? null
            : session?.host ?? savedAccountHost ?? origin;
        _userAgent = session?.userAgent ?? _defaultUserAgent;
        _initialized = true;
      }
    } finally {
      _initializing = null;
    }
  }

  @override
  Future<VideoCatalogPage> browse(
    String url, {
    CancelToken? cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    if (cancelToken?.cancelError case final error?) throw error;
    await _prepareOnlineAccess();
    final requestCancelToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(requestCancelToken);
    try {
      return await _browse(
        _localizedSourceUri(url, remap: false),
        cancelToken: requestCancelToken,
        onParsed: onParsed,
      );
    } finally {
      _browseCancelTokens.remove(requestCancelToken);
    }
  }

  Future<_ContentPage> _loadContentPage(
    Uri sourceUri,
    int generation,
    String locale,
    CancelToken cancelToken, {
    bool details = false,
    bool accountPage = false,
  }) => _ContentLineLoader(
    this,
    sourceUri,
    generation: generation,
    locale: locale,
    cancelToken: cancelToken,
    details: details,
    accountPage: accountPage,
  ).load();

  Future<String?> loadPlaylistCover(
    String url, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.cancelError case final error?) throw error;
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final playlistUri = _localizedSourceUri(url, remap: false).removeFragment();
    final queryParameters = <String, dynamic>{
      for (final entry in playlistUri.queryParametersAll.entries)
        if (entry.key != 'page')
          entry.key: entry.value.length == 1 ? entry.value.single : entry.value,
    };
    final firstPage = queryParameters.isEmpty
        ? Uri.parse(playlistUri.toString().split('?').first)
        : playlistUri.replace(queryParameters: queryParameters);
    final requestCancelToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(requestCancelToken);
    try {
      final (:document, :uri, title: _, streams: _) = await _loadContentPage(
        firstPage,
        generation,
        locale,
        requestCancelToken,
      );
      final videos = _parseVideos(document, uri);
      final cover = videos.isEmpty ? null : videos.first.cover;
      return cover == null || cover.isEmpty ? null : cover;
    } finally {
      _browseCancelTokens.remove(requestCancelToken);
    }
  }

  Future<void> checkBrowserAccess({
    Map<String, dynamic>? browserUser,
    CancelToken? cancelToken,
  }) async {
    await initialize();
    final browser = _browserAdapter;
    if (browser == null ||
        (browser is MissavBrowserAdapter && browser.isClosed)) {
      await _prepareOnlineAccess();
    }
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = Uri.parse('$_activeAccountBaseUrl$_localePrefix');
    final (document: document, uri: pageUri) = await _loadDocument(
      uri,
      generation,
      cancelToken: cancelToken,
      isContentPage: true,
    );
    _checkGeneration(generation, uri);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    final sourceUser = _readAccountFromPage(document) ?? browserUser;
    if (sourceUser != null) _updateAccountFromSource(sourceUser);
    if (pageUri.origin == _baseUrl) _updateHomeUrl(document, pageUri);
  }

  Future<bool> restoreAccount({bool recheck = false}) async {
    if (!recheck && isLoggedIn) return true;
    await _prepareOnlineAccess();
    if (!recheck && isLoggedIn) return true;
    if (_accountRestore case final pending?) return pending;
    if (!hasRestorableSession) {
      if (isLoggedIn) await _clearSession(_advanceSessionGeneration());
      return false;
    }
    final pending = _restoreAccount(_sessionGeneration);
    _accountRestore = pending;
    try {
      return await pending;
    } finally {
      if (identical(_accountRestore, pending)) _accountRestore = null;
    }
  }

  Future<bool> _restoreAccount(int generation) async {
    final uri = Uri.parse('$_activeAccountBaseUrl/en/saved');
    try {
      final (:document, uri: pageUri) = await _loadDocument(
        uri,
        generation,
        isContentPage: true,
      );
      final sourceUser = _readAccountFromPage(document);
      if (pageUri.origin == uri.origin && sourceUser != null) {
        _updateAccountFromSource(sourceUser);
        return true;
      }
      if (pageUri.origin == uri.origin &&
          (pageUri.pathSegments.lastOrNull == 'login' ||
              (pageUri.path == uri.path &&
                  document
                      .querySelectorAll('main a, main button')
                      .any((control) => control.text.trim() == 'Login')))) {
        throw MissavAuthenticationException(sourceUrl: uri.toString());
      }
      if (isLoggedIn) return true;
      throw MissavException(
        'MissAV could not confirm the saved account session.',
        sourceUrl: uri.toString(),
      );
    } on MissavAuthenticationException {
      _checkGeneration(generation, uri);
      if (_browserAdapter == null) {
        _advanceSessionGeneration();
      } else {
        restoreNativeTransport();
      }
      await _clearSession(_sessionGeneration);
      return false;
    }
  }

  Future<VideoCatalogPage> _browse(
    Uri sourceUri, {
    required CancelToken cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    final generation = _sessionGeneration;
    final locale = _locale;
    var uri = _remapSource(sourceUri);
    final searchQuery = _searchQuery(sourceUri);
    final currentPage = _pageNumber(sourceUri) ?? 1;
    final searchPage = searchQuery == null
        ? null
        : await _searchRecommendations(
            searchQuery,
            currentPage,
            uri,
            generation: generation,
            locale: locale,
            cancelToken: cancelToken,
          );
    final VideoCatalogPage parsedPage;
    if (searchPage != null) {
      String pageUrl(int page) => uri
          .replace(queryParameters: {...uri.queryParameters, 'page': '$page'})
          .toString();
      parsedPage = VideoCatalogPage(
        title: searchQuery!,
        url: uri.toString(),
        videos: searchPage.videos,
        nextUrl: searchPage.cursor == null ? null : pageUrl(currentPage + 1),
        previousUrl: currentPage > 1 ? pageUrl(currentPage - 1) : null,
        currentPage: currentPage,
      );
    } else {
      final accountUri = _accountPageUri(sourceUri);
      final page = await _loadContentPage(
        accountUri ?? sourceUri,
        generation,
        locale,
        cancelToken,
        accountPage: accountUri != null,
      );
      uri = page.uri;
      _updateAccountFromPage(page.document, uri);
      var previousUrl = _paginationUrl(page.document, uri, 'prev');
      if (searchQuery != null && previousUrl != null) {
        final previous = Uri.parse(previousUrl);
        if (_pageNumber(previous) == null) {
          previousUrl = previous
              .replace(
                queryParameters: {...previous.queryParameters, 'page': '1'},
              )
              .toString();
        }
      }
      parsedPage = VideoCatalogPage(
        title: _pageTitle(page.document),
        url: uri.toString(),
        videos: _parseVideos(page.document, uri),
        links: _parseLinks(page.document, uri),
        navigation: _parseNavigation(page.document, uri),
        nextUrl: _paginationUrl(page.document, uri, 'next'),
        previousUrl: previousUrl,
        currentPage: _pageNumber(uri) ?? 1,
        jumpMaxPage: _jumpMaxPage(page.document, uri),
      );
    }
    _checkContentRequest(uri, generation, locale, cancelToken);
    onParsed?.call(parsedPage);
    final enriched = await _enrichVideos(
      parsedPage.videos,
      uri,
      cancelToken: cancelToken,
    );
    _checkContentRequest(uri, generation, locale, cancelToken);

    return VideoCatalogPage(
      title: parsedPage.title,
      url: parsedPage.url,
      videos: enriched,
      links: parsedPage.links,
      navigation: parsedPage.navigation,
      nextUrl: parsedPage.nextUrl,
      previousUrl: parsedPage.previousUrl,
      currentPage: parsedPage.currentPage,
      jumpMaxPage: parsedPage.jumpMaxPage,
    );
  }

  Future<VideoRecommendationPage> loadRecommendations({
    String? cursor,
    required int count,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.cancelError case final error?) throw error;
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    var uri = _localizedSourceUri(homeUrl, remap: false);
    final requestCancelToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(requestCancelToken);
    try {
      if (requestCancelToken.cancelError case final error?) throw error;
      if (cursor == null) {
        _recommendationUserId = null;
        _recommendationScenario = null;
        final page = await _loadContentPage(
          uri,
          generation,
          locale,
          requestCancelToken,
        );
        uri = page.uri;
        _updateAccountFromPage(page.document, uri);
      }
      final userId = _recommendationUserId ?? 'anonymous';
      final scenario = _recommendationScenario ?? 'desktop-home-recommended';
      final path = cursor == null
          ? '/missav-default/recomms/users/${Uri.encodeComponent(userId)}/items/'
          : '/missav-default/recomms/next/items/${Uri.encodeComponent(cursor)}';
      final data = await _requestRecommendations(path, {
        'count': count,
        'cascadeCreate': true,
        if (cursor == null) ...{
          'scenario': scenario,
          'returnProperties': true,
          'filter': null,
          'logic': {
            'name': 'missav:personal',
            'settings': {'spotlightVideoIds': <String>[]},
          },
        },
      }, cancelToken: requestCancelToken);
      _checkGeneration(generation, uri);
      if (_locale != locale) {
        throw MissavException(
          'MissAV language changed during the request.',
          sourceUrl: uri.toString(),
        );
      }
      if (data is! Map ||
          data['recomms'] is! List ||
          data['recommId'] is! String) {
        throw MissavException(
          'MissAV returned invalid recommendations.',
          sourceUrl: uri.toString(),
        );
      }
      final recommId = data['recommId'] as String;
      final videos = <VideoItem>[];
      for (final entry in data['recomms'] as List) {
        if (entry is! Map ||
            entry['id'] is! String ||
            entry['values'] is! Map) {
          throw MissavException(
            'MissAV returned an invalid recommendation.',
            sourceUrl: uri.toString(),
          );
        }
        final id = entry['id'] as String;
        final values = entry['values'] as Map;
        videos.add(
          _recommendationVideo(
            id,
            values,
            locale,
            uri,
            fragment: '${recommId}_$scenario',
          ),
        );
      }
      if (requestCancelToken.cancelError case final error?) throw error;
      return VideoRecommendationPage(videos: videos, cursor: recommId);
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      throw MissavException(
        'MissAV recommendations could not be loaded.',
        sourceUrl: uri.toString(),
        cause: error,
      );
    } finally {
      _browseCancelTokens.remove(requestCancelToken);
    }
  }

  Future<VideoRecommendationPage?> _searchRecommendations(
    String query,
    int page,
    Uri uri, {
    required int generation,
    required String locale,
    required CancelToken cancelToken,
  }) async {
    _checkContentRequest(uri, generation, locale, cancelToken);
    final key = '$locale:$query';
    var search = _searches[key];
    if (page <= 1 && (_pageNumber(uri) == null || search == null)) {
      search = _MissavSearchState();
      _searches[key] = search;
    }
    if (search == null || search.usesHtml) return null;
    final state = search;
    final request = state.pages.putIfAbsent(page, () {
      final pending = _MissavSearchPageRequest();
      pending.response = _requestSearchPage(
        query,
        page,
        uri,
        state,
        generation: generation,
        locale: locale,
        cancelToken: page > 1 ? pending.cancelToken : cancelToken,
      ).whenComplete(() => pending.isPending = false);
      return pending;
    });
    request.waiters++;
    try {
      VideoRecommendationPage? result;
      DioException? requestError;
      try {
        result = await Future.any<VideoRecommendationPage?>([
          request.response,
          cancelToken.whenCancel.then<VideoRecommendationPage?>(
            (error) => throw error,
          ),
        ]);
      } on DioException catch (error) {
        requestError = error;
      }
      _checkContentRequest(uri, generation, locale, cancelToken);
      if (!identical(_searches[key], state)) {
        throw MissavException(
          'MissAV search changed during the request.',
          sourceUrl: uri.toString(),
        );
      }
      if (requestError != null) {
        if (requestError.type != DioExceptionType.cancel) throw requestError;
        state.usesHtml = true;
      }
      return result;
    } finally {
      request.waiters--;
      if (page > 1 &&
          cancelToken.isCancelled &&
          request.waiters == 0 &&
          request.isPending) {
        state.usesHtml = true;
        request.cancelToken.cancel();
      }
    }
  }

  Future<VideoRecommendationPage?> _requestSearchPage(
    String query,
    int page,
    Uri uri,
    _MissavSearchState search, {
    required int generation,
    required String locale,
    required CancelToken cancelToken,
  }) async {
    final previous = await search.pages[page - 1]?.response;
    _checkContentRequest(uri, generation, locale, cancelToken);
    final cursor = previous?.cursor;
    if (page > 1 && cursor == null) {
      search.usesHtml = true;
      return null;
    }
    final Map<String, Object?> data;
    final String path;
    if (page <= 1 || cursor == null) {
      path = '/missav-default/search/users/anonymous/items/';
      data = {
        'searchQuery': query,
        'count': 24,
        'scenario': 'search',
        'returnProperties': true,
        'includedProperties': [
          'title_en',
          if (_locale != 'en') _locale == 'ja' ? 'title' : 'title_$_locale',
          'dm',
        ],
        'cascadeCreate': true,
      };
    } else {
      path = '/missav-default/recomms/next/items/$cursor';
      data = {'count': 24, 'cascadeCreate': true};
    }
    Object? response;
    try {
      response = await _requestRecommendations(
        path,
        data,
        cancelToken: cancelToken,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
    }
    _checkContentRequest(uri, generation, locale, cancelToken);
    if (response is! Map ||
        response['recomms'] is! List ||
        response['recommId'] is! String ||
        (response['recommId'] as String).isEmpty) {
      search.usesHtml = true;
      return null;
    }
    final recommId = response['recommId'] as String;
    final videos = <VideoItem>[];
    for (final entry in response['recomms'] as List) {
      if (entry is! Map ||
          entry['id'] is! String ||
          (entry['id'] as String).isEmpty ||
          entry['values'] is! Map) {
        search.usesHtml = true;
        return null;
      }
      videos.add(
        _recommendationVideo(
          entry['id'] as String,
          entry['values'] as Map,
          locale,
          uri,
        ),
      );
    }
    return VideoRecommendationPage(
      videos: videos,
      cursor: videos.isEmpty ? null : recommId,
    );
  }

  VideoItem _recommendationVideo(
    String id,
    Map values,
    String titleLocale,
    Uri uri, {
    String? fragment,
  }) {
    final title = values[titleLocale == 'ja' ? 'title' : 'title_$titleLocale'];
    final dm = values['dm'];
    final prefix = dm is num && dm > 0 ? '/dm${dm.toInt()}' : '';
    final duration = values['duration'];
    return _withVideoMetadata(
      VideoItem(
        id: id,
        title: title is String && title.isNotEmpty
            ? '${id.toUpperCase().replaceAll(RegExp(r'-(UNCENSORED-LEAK|CHINESE-SUBTITLE|ENGLISH-SUBTITLE)'), '')} $title'
            : id.toUpperCase(),
        pageUrl: Uri.parse(
          '${uri.origin}$prefix$_localePrefix/${Uri.encodeComponent(id)}',
        ).replace(fragment: fragment).toString(),
        cover: 'https://fourhoi.com/${Uri.encodeComponent(id)}/cover-t.jpg',
        durationSeconds: duration is num ? duration.round() : null,
        hasSubtitles:
            values['has_chinese_subtitle'] == true ||
            values['has_english_subtitle'] == true,
        isUncensored: values['is_uncensored_leak'] == true,
      ),
      values,
      _localePrefix,
      uri.origin,
    );
  }

  Future<List<VideoItem>> loadRelatedRecommendations(
    VideoItem video, {
    CancelToken? cancelToken,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = _localizedSourceUri(video.pageUrl);
    final visitor = _recommendationUserId ?? 'anonymous';
    try {
      final data = await _requestRecommendations('/missav-default/batch/', {
        'distinctRecomms': true,
        'requests': [
          for (final scenario in [
            'desktop-watch-next-side',
            'desktop-watch-next-bottom',
          ])
            {
              'method': 'POST',
              'path': '/recomms/items/${Uri.encodeComponent(video.id)}/items/',
              'params': {
                'targetUserId': visitor,
                'count': 24,
                'scenario': scenario,
                'returnProperties': true,
                'includedProperties': [
                  'title_en',
                  if (locale != 'en')
                    locale == 'ja' ? 'title' : 'title_$locale',
                  'dm',
                ],
                'cascadeCreate': true,
              },
            },
        ],
      }, cancelToken: cancelToken);
      _checkCancelled(cancelToken, uri);
      _checkGeneration(generation, uri);
      if (_locale != locale) {
        throw MissavException(
          'MissAV language changed during the request.',
          sourceUrl: uri.toString(),
        );
      }
      if (data is! List || data.length != 2) {
        throw MissavException(
          'MissAV returned invalid related recommendations.',
          sourceUrl: uri.toString(),
        );
      }
      final videos = <VideoItem>[];
      final seen = {video.id.toLowerCase()};
      for (final result in data) {
        if (result is! Map ||
            result['code'] is! int ||
            (result['code'] as int) < 200 ||
            (result['code'] as int) >= 300 ||
            result['json'] is! Map) {
          throw MissavException(
            'MissAV returned invalid related recommendations.',
            sourceUrl: uri.toString(),
          );
        }
        final body = result['json'] as Map;
        if (body['recommId'] is! String || body['recomms'] is! List) {
          throw MissavException(
            'MissAV returned invalid related recommendations.',
            sourceUrl: uri.toString(),
          );
        }
        for (final entry in body['recomms'] as List) {
          if (entry is! Map ||
              entry['id'] is! String ||
              entry['values'] is! Map) {
            throw MissavException(
              'MissAV returned an invalid related recommendation.',
              sourceUrl: uri.toString(),
            );
          }
          final id = entry['id'] as String;
          if (id.isEmpty || !seen.add(id.toLowerCase())) continue;
          final values = entry['values'] as Map;
          final localizedTitle =
              values[locale == 'ja' ? 'title' : 'title_$locale'];
          final titleLocale =
              localizedTitle is String && localizedTitle.isNotEmpty
              ? locale
              : 'en';
          videos.add(_recommendationVideo(id, values, titleLocale, uri));
        }
      }
      final enriched = await _enrichVideos(
        videos,
        uri,
        cancelToken: cancelToken,
      );
      _checkCancelled(cancelToken, uri);
      _checkGeneration(generation, uri);
      if (_locale != locale) {
        throw MissavException(
          'MissAV language changed during the request.',
          sourceUrl: uri.toString(),
        );
      }
      return enriched;
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      throw MissavException(
        'MissAV related recommendations could not be loaded.',
        sourceUrl: uri.toString(),
        cause: error,
      );
    }
  }

  Future<Object?> _requestRecommendations(
    String path,
    Map<String, Object?> data, {
    CancelToken? cancelToken,
  }) async {
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final unsigned = '$path?frontend_timestamp=$timestamp';
    final signature = Hmac(
      sha1,
      utf8.encode(_metadataPublicToken),
    ).convert(utf8.encode(unsigned));
    final response = await _metadataDio.post<Object?>(
      'https://client-rapi-missav.recombee.com$unsigned&frontend_sign=$signature',
      data: data,
      cancelToken: cancelToken ?? _sessionCancelToken,
      options: Options(
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
      ),
    );
    return response.data;
  }

  Future<List<VideoItem>> _enrichVideos(
    List<VideoItem> videos,
    Uri uri, {
    CancelToken? cancelToken,
  }) async {
    if (videos.isEmpty) return videos;
    final localePrefix = _localePrefix;
    final ids = videos
        .map((video) => video.id.toLowerCase())
        .where((id) => RegExp(r'^[a-z0-9_:@.\-]+$').hasMatch(id))
        .toSet();
    if (ids.isEmpty) return videos;
    try {
      final data = await _requestRecommendations(
        '/missav-default/recomms/users/anonymous/items/',
        {
          'count': ids.length,
          'cascadeCreate': true,
          'returnProperties': true,
          'filter': "'itemId' in {${ids.map(jsonEncode).join(',')}}",
        },
        cancelToken: cancelToken ?? _sessionCancelToken,
      );
      if (data is! Map || data['recomms'] is! List) return videos;
      final valuesById = <String, Map>{};
      for (final entry in data['recomms'] as List) {
        if (entry is! Map ||
            entry['id'] is! String ||
            entry['values'] is! Map) {
          continue;
        }
        final id = (entry['id'] as String).toLowerCase();
        if (ids.contains(id)) valuesById[id] = entry['values'] as Map;
      }
      return videos.map((video) {
        final values = valuesById[video.id.toLowerCase()];
        if (values == null) return video;
        return _withVideoMetadata(video, values, localePrefix, uri.origin);
      }).toList();
    } catch (_) {
      // Catalog browsing stays available when optional metadata cannot be read.
      return videos;
    }
  }

  VideoItem _withVideoMetadata(
    VideoItem video,
    Map values,
    String localePrefix,
    String baseUrl,
  ) {
    List<String> names(String field) {
      final value = values[field];
      if (value is! List) return [];
      return value
          .whereType<String>()
          .map((name) => name.trim())
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList();
    }

    List<VideoLink> links(String field, String route, VideoLinkKind kind) {
      // Recombee genre names use MissAV's Japanese slugs.
      final prefix = field == 'genres' ? '/ja' : localePrefix;
      return names(field)
          .map(
            (name) => VideoLink(
              label: name,
              url: '$baseUrl$prefix/$route/${Uri.encodeComponent(name)}',
              kind: kind,
            ),
          )
          .toList();
    }

    final actors = <String, VideoLink>{
      for (final actor in links('actresses', 'actresses', VideoLinkKind.actor))
        actor.label: actor,
      for (final actor in video.actors) actor.label: actor,
    };
    final tags = <(String?, String), VideoLink>{
      for (final tag in links('genres', 'genres', VideoLinkKind.category))
        (tag.cardMetadataRoute, tag.label): tag,
      for (final tag in video.tags) (tag.cardMetadataRoute, tag.label): tag,
    };
    final duration = values['duration'];
    final releasedAt = values['released_at'];
    return VideoItem(
      id: video.id,
      title: video.title,
      pageUrl: video.pageUrl,
      cover: video.cover,
      durationSeconds: duration is num && duration > 0
          ? duration.round()
          : video.durationSeconds,
      releaseDate: releasedAt is num && releasedAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              (releasedAt * 1000).round(),
              isUtc: true,
            ).toIso8601String().substring(0, 10)
          : video.releaseDate,
      actors: actors.values.toList(),
      tags: tags.values.toList(),
      makers: {...video.makers, ...names('markers')}.toList(),
      labels: {...video.labels, ...names('labels')}.toList(),
      series: {...video.series, ...names('series')}.toList(),
      directors: {...video.directors, ...names('directors')}.toList(),
      hasSubtitles:
          video.hasSubtitles ||
          values['has_chinese_subtitle'] == true ||
          values['has_english_subtitle'] == true,
      isUncensored:
          video.isUncensored ||
          values['is_uncensored_leak'] == true ||
          _uncensoredTypes.contains(values['type']),
    );
  }

  @override
  Future<VideoCatalogPage> search(String query) async {
    final path = '$_localePrefix/search/${Uri.encodeComponent(query)}';
    return browse('$_baseUrl$path');
  }

  @override
  Future<VideoCatalogPage> searchFilterOptions(
    VideoSearchFilterKind kind, {
    String? pageUrl,
  }) async {
    final route = switch (kind) {
      VideoSearchFilterKind.genre => 'genres',
      VideoSearchFilterKind.actor => 'actresses',
      VideoSearchFilterKind.studio => 'makers',
      VideoSearchFilterKind.series => 'series',
    };
    final roots = switch (kind) {
      VideoSearchFilterKind.genre => const {
        'genre',
        'genres',
        'category',
        'categories',
        'tag',
        'tags',
      },
      VideoSearchFilterKind.actor => const {'actresses', 'actors'},
      VideoSearchFilterKind.studio => const {
        'maker',
        'makers',
        'studio',
        'studios',
      },
      VideoSearchFilterKind.series => const {'series'},
    };
    final page = await browse(pageUrl ?? '$_baseUrl$_localePrefix/$route');
    return VideoCatalogPage(
      title: page.title,
      url: page.url,
      links: page.links
          .where((link) {
            final segments = Uri.parse(link.url).pathSegments
                .where((segment) => segment.isNotEmpty)
                .skipWhile(
                  (segment) =>
                      _sourceLanguages.contains(segment) ||
                      RegExp(r'^dm\d+$').hasMatch(segment),
                )
                .toList();
            return segments.length == 2 &&
                roots.contains(segments.first) &&
                segments.last != 'ranking';
          })
          .toList(growable: false),
      nextUrl: page.nextUrl,
      previousUrl: page.previousUrl,
      currentPage: page.currentPage,
      jumpMaxPage: page.jumpMaxPage,
    );
  }

  @override
  Future<List<VideoItem>> searchWithFilters(
    String query,
    List<VideoLink> filters, {
    bool Function()? isCurrent,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final keyword = query.trim();
    // shortcut: Large catalogs need full pagination until a native combined-search API is verified.
    final urls = <String>{
      if (keyword.isNotEmpty)
        '$_baseUrl$_localePrefix/search/${Uri.encodeComponent(keyword)}',
      for (final filter in filters) _localizedSourceUri(filter.url).toString(),
    };
    return intersectVideoCatalogs(
      urls: urls,
      browse: (url) async {
        final requestUri = _localizedSourceUri(url);
        final parameters = Map<String, String>.of(requestUri.queryParameters)
          ..remove('page');
        final sourceUri = requestUri.removeFragment().replace(
          queryParameters: parameters,
        );
        _checkGeneration(generation, sourceUri);
        final page = await browse(url);
        if (isCurrent?.call() == false || _locale != locale) return page;
        _checkGeneration(generation, sourceUri);
        return page;
      },
      isCurrent: () => isCurrent?.call() != false && _locale == locale,
    );
  }

  Future<List<VideoItem>> searchCollection(
    String url,
    String query, {
    bool Function()? isCurrent,
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final first = _localizedSourceUri(url);
    final parameters = Map<String, String>.of(first.queryParameters)
      ..remove('page');
    String? next = first.replace(queryParameters: parameters).toString();
    final visited = <String>{};
    final seen = <String>{};
    final matches = <VideoItem>[];
    final needle = query.trim().toLowerCase();
    while (next != null && visited.add(next)) {
      if (isCurrent?.call() == false || _locale != locale) return [];
      _checkGeneration(generation, first);
      final page = await browse(next);
      if (isCurrent?.call() == false || _locale != locale) return [];
      _checkGeneration(generation, first);
      for (final video in page.videos) {
        if (seen.add(video.id) &&
            '${video.id} ${video.title}'.toLowerCase().contains(needle)) {
          matches.add(video);
        }
      }
      next = page.nextUrl;
    }
    return matches;
  }

  @override
  Future<VideoDetails> details(
    VideoItem item, {
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
    CancelToken? cancelToken,
  }) async {
    cancelBackgroundMirrorProbe();
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final contentToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(contentToken);
    final ({
      Document document,
      Uri uri,
      String? title,
      List<VideoStream> streams,
    })
    content;
    try {
      content = await _loadContentPage(
        _localizedSourceUri(item.pageUrl, remap: false),
        generation,
        locale,
        contentToken,
        details: true,
      );
    } finally {
      _browseCancelTokens.remove(contentToken);
    }
    final (:document, :uri, :title, :streams) = content;
    _updateAccountFromPage(document, uri);
    final poster = document
        .querySelector('video[data-poster]')
        ?.attributes['data-poster'];
    final parsedActors = _parseDetailLinks(document, uri, VideoLinkKind.actor);
    final parsedTags = _parseDetailLinks(document, uri, VideoLinkKind.tag);
    final actors = parsedActors.isEmpty ? item.actors : parsedActors;
    final tags = parsedTags.isEmpty ? item.tags : parsedTags;
    final labels = '${uri.path} ${tags.map((tag) => tag.label).join(' ')}';
    final video = VideoItem(
      id: item.id,
      title: title?.isNotEmpty == true ? title! : item.title,
      pageUrl: uri.toString(),
      cover: poster?.isNotEmpty == true
          ? uri.resolve(poster!).toString()
          : item.cover,
      durationSeconds: item.durationSeconds,
      releaseDate:
          _releaseDate(
            _detailMetadataRows(
              document,
            ).expand((row) => row.querySelectorAll('time')),
          ) ??
          item.releaseDate,
      actors: actors,
      tags: tags,
      makers: item.makers,
      labels: item.labels,
      series: item.series,
      directors: item.directors,
      hasSubtitles: item.hasSubtitles || _hasSubtitleLabel(labels),
      isUncensored: item.isUncensored || _hasUncensoredLabel(labels),
    );
    final metadata = _parseMetadata(document, uri, [...actors, ...tags], video);
    final sourceId = _sourceId(document);
    final saved = _officialHosts.contains(uri.host)
        ? _savedState(document)
        : null;
    final related = _parseVideos(
      document,
      uri,
    ).where((related) => related.id != item.id).toList();
    final initialDetails = VideoDetails(
      video: video,
      description: _parseDescription(document),
      metadata: metadata,
      related: related,
      streams: streams,
      sourceId: sourceId,
      isFavorite: sourceId == null ? saved : null,
    );
    await onReady?.call(initialDetails);
    return _supplementDetails(
      initialDetails,
      generation: generation,
      locale: locale,
      saved: saved,
      onReady: onReady,
      includeAccountState: includeAccountState,
      cancelToken: cancelToken,
    );
  }

  Future<VideoDetails> supplementDetails(
    VideoDetails details, {
    FutureOr<void> Function(VideoDetails)? onReady,
    CancelToken? cancelToken,
  }) async {
    await _prepareOnlineAccess();
    return _supplementDetails(
      details,
      generation: _sessionGeneration,
      locale: _locale,
      saved: details.isFavorite,
      onReady: onReady,
      cancelToken: cancelToken,
    );
  }

  Future<VideoDetails> _supplementDetails(
    VideoDetails initialDetails, {
    required int generation,
    required String locale,
    bool? saved,
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
    CancelToken? cancelToken,
  }) async {
    final uri = _sourceUri(initialDetails.video.pageUrl);
    _checkGeneration(generation, uri);
    final enrichment = _enrichVideos(
      [initialDetails.video, ...initialDetails.related],
      uri,
      cancelToken: cancelToken,
    );
    final sourceId = initialDetails.sourceId;
    Object? accountError;
    StackTrace? accountTrace;
    final accountBase = _activeAccountBaseUrl;
    if (sourceId != null &&
        includeAccountState &&
        (_officialHosts.contains(uri.host) ||
            _isLoggedIn ||
            (hasRestorableSession && !_confirmedGuest))) {
      final viewUri = Uri.parse(
        '$accountBase/api/items/${Uri.encodeComponent(sourceId)}/view',
      );
      try {
        final viewResponse = await _request(
          viewUri,
          generation: generation,
          cancelToken: cancelToken,
        );
        _checkCancelled(cancelToken, uri);
        _checkGeneration(generation, viewUri);
        final viewBody = _decodeObject(viewResponse.data, viewUri);
        if (viewBody['saved'] is bool) saved = viewBody['saved'] as bool;
        if (viewBody.containsKey('user')) {
          _updateAccountFromSource(viewBody['user']);
        }
      } catch (error, trace) {
        if (error is! MissavVerificationRequiredException &&
            error is! MissavAuthenticationException) {
          accountError = error;
          accountTrace = trace;
        }
        saved = null;
      }
      _checkCancelled(cancelToken, uri);
    }
    final enriched = await enrichment;
    _checkCancelled(cancelToken, uri);
    final detailedVideo = enriched.first;
    _checkGeneration(generation, uri);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    final details = VideoDetails(
      video: detailedVideo,
      description: initialDetails.description,
      metadata: _metadataWithoutVideoGroups(
        initialDetails.metadata,
        detailedVideo,
      ),
      related: enriched.skip(1).toList(),
      streams: initialDetails.streams,
      sourceId: sourceId,
      isFavorite: saved,
    );
    if (accountError != null) {
      await onReady?.call(details);
      Error.throwWithStackTrace(accountError, accountTrace!);
    }
    return details;
  }

  Future<void> login({required String email, required String password}) async {
    await _prepareOnlineAccess();
    if (_browserAdapter != null) {
      await _loginAt(origin, email: email, password: password);
      return;
    }
    final previous = _accountBaseUrl;
    final hosts = [previous, ...accountHosts.where((host) => host != previous)];
    MissavException? lastError;
    for (final host in hosts) {
      try {
        await _loginAt(host, email: email, password: password);
        await selectAccountHost(host);
        return;
      } on MissavAuthenticationException {
        rethrow;
      } on MissavException catch (error) {
        if (!_canRetryLogin(error)) rethrow;
        lastError = error;
      }
    }
    throw lastError ?? const MissavException('MissAV login failed.');
  }

  static bool _canRetryLogin(MissavException error) {
    if (error is MissavAuthenticationException ||
        error is MissavVerificationRequiredException ||
        error is MissavAccessDeniedException ||
        error is MissavRateLimitException) {
      return false;
    }
    if (error.message.contains('account changed')) return false;
    final cause = error.cause;
    return cause is! DioException || cause.type != DioExceptionType.cancel;
  }

  Future<void> _loginAt(
    String base, {
    required String email,
    required String password,
  }) async {
    final generation = _advanceSessionGeneration();
    _confirmedGuest = false;
    final uri = Uri.parse('$base/en/api/login');
    final pageUri = Uri.parse('$base/en');
    final login = _MissavLoginCookies(
      base,
      _sessionHost == base ? _cookies : const _MissavCookies(),
    );
    if (_resetMedia case final resetMedia?) {
      await resetMedia();
      _checkGeneration(generation, uri);
    }

    Future<Response<dynamic>> sendLogin() => _request(
      uri,
      method: 'POST',
      data: {'email': email, 'password': password, 'remember': true},
      generation: generation,
      login: login,
    );

    try {
      if (_cookieValue(login.cookies.header, 'XSRF-TOKEN') == null) {
        await _request(
          pageUri,
          generation: generation,
          direct: true,
          login: login,
        );
      }
      late Response<dynamic> response;
      try {
        response = await sendLogin();
      } on MissavException catch (error) {
        if (!error.message.contains('HTTP 419')) rethrow;
        await _request(
          pageUri,
          generation: generation,
          direct: true,
          login: login,
        );
        response = await sendLogin();
      }
      if (generation != _sessionGeneration) {
        throw const MissavException('MissAV account changed during login.');
      }

      final raw = response.data;
      final text = raw is String ? raw : jsonEncode(raw);
      Object? decoded;
      if (raw is Map) {
        decoded = raw;
      } else {
        try {
          decoded = jsonDecode(text);
        } on FormatException {
          // The source may return HTML after a redirect.
        }
      }
      Map<String, dynamic>? user;
      if (decoded is Map && decoded['user'] is Map) {
        user = Map<String, dynamic>.from(decoded['user'] as Map);
      }
      final sourceMessage = decoded is Map ? decoded['message'] : null;
      if (user == null &&
          sourceMessage is String &&
          sourceMessage.trim().isNotEmpty) {
        throw MissavAuthenticationException(
          message: sourceMessage.trim(),
          sourceUrl: uri.toString(),
        );
      }
      user ??= readAccountFromMarkup(text, uri);
      if (user == null) {
        final homeUri = Uri.parse('$base/en');
        final homeResponse = await _request(
          homeUri,
          generation: generation,
          direct: true,
          login: login,
        );
        final homeText = homeResponse.data is String
            ? homeResponse.data as String
            : '';
        user = readAccountFromMarkup(homeText, homeUri);
      }
      if (user == null) {
        throw MissavException(
          'MissAV returned an invalid login response.',
          sourceUrl: uri.toString(),
        );
      }
      final browser = _browserAdapter;
      if (browser is MissavBrowserAdapter) {
        try {
          final cookie = await browser.readCookieHeader?.call();
          if (cookie != null && cookie.isNotEmpty) {
            _checkGeneration(generation, uri);
            _validateHeaderValue(cookie, 'cookieHeader');
            login.cookies = login.cookies.withBrowserHeader(cookie);
          }
        } catch (_) {}
      }
      _checkGeneration(generation, uri);
      await _writeSession(generation, () async {
        if (login.cookies.header != null || _cookies.header != null) {
          await _persistSession(
            generation,
            cookies: login.cookies,
            userAgent: _userAgent,
            host: base,
          );
        }
        _checkGeneration(generation, uri);
        _cookies = login.cookies;
        _sessionHost = base;
      });
      _checkGeneration(generation, uri);
      _accountName = _accountNameFrom(user) ?? email;
      _setAccountState(loggedIn: true, notify: false);
      if (browser != null) {
        resumeContentBrowsing();
      } else {
        notifyListeners();
      }
    } on MissavException {
      rethrow;
    } on DioException catch (error) {
      throw MissavException(
        'MissAV login failed (${error.response?.statusCode ?? error.type.name}).',
        sourceUrl: uri.toString(),
        cause: error,
      );
    } on FormatException {
      throw MissavException(
        'MissAV returned an invalid login response.',
        sourceUrl: uri.toString(),
      );
    }
  }

  Future<void> logout() async {
    await initialize();
    restoreNativeTransport();
    await _clearSession(_advanceSessionGeneration());
  }

  Future<void> importVerifiedSession({
    required String cookieHeader,
    required String userAgent,
    int? expectedGeneration,
  }) async {
    _validateHeaderValue(cookieHeader, 'cookieHeader');
    _validateHeaderValue(userAgent, 'userAgent');
    final previousGeneration = expectedGeneration ?? _sessionGeneration;
    await initialize();
    _checkGeneration(previousGeneration, Uri.parse(origin));

    final generation = _advanceSessionGeneration();
    if (_resetMedia case final resetMedia?) {
      await resetMedia();
      _checkGeneration(generation, Uri.parse(origin));
    }
    final accountChanged = _isLoggedIn || _accountName != null;
    final cookies = _MissavCookies.fromHeader(cookieHeader);
    _cookies = cookies;
    _sessionHost = origin;
    _confirmedGuest = false;
    _userAgent = userAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();

    await _writeSession(generation, () async {
      await _persistSession(
        generation,
        cookies: cookies,
        userAgent: userAgent,
        host: origin,
      );
    });
    if (generation != _sessionGeneration || _disposed) {
      throw const MissavException(
        'MissAV account changed during session import.',
      );
    }
  }

  Future<void> setVideoFavorite(VideoDetails details, bool favorite) async {
    await _prepareOnlineAccess();
    final base = _activeAccountBaseUrl;
    final sourceId = details.sourceId;
    if (sourceId == null || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sourceId)) {
      throw MissavUnsupportedException(
        capability: 'video favorites without a source item ID',
        sourceUrl: details.video.pageUrl,
      );
    }
    await _request(
      Uri.parse('$base/api/items/${Uri.encodeComponent(sourceId)}/save'),
      method: favorite ? 'POST' : 'DELETE',
    );
  }

  Future<List<VideoLink>> playlistsFor(VideoItem item) async {
    await _prepareOnlineAccess();
    final base = _activeAccountBaseUrl;
    _sourceUri(item.pageUrl);
    final uri = Uri.parse(
      '$base/api/playlists/${Uri.encodeComponent(item.id)}',
    );
    final response = await _request(uri);
    final body = _decodeObject(response.data, uri);
    final entries = body['data'];
    if (entries is! List) {
      throw MissavException(
        'MissAV returned an invalid playlist response.',
        sourceUrl: uri.toString(),
      );
    }
    return entries
        .whereType<Map>()
        .map((entry) {
          final key = entry['key'];
          final name = entry['name'];
          if (key is! String || name is! String) return null;
          return VideoLink(
            label: name,
            url: collectionUrl('playlists'),
            kind: VideoLinkKind.playlist,
            sourceKey: key,
            isAdded: entry['is_added'] is bool
                ? entry['is_added'] as bool
                : null,
          );
        })
        .whereType<VideoLink>()
        .toList();
  }

  Future<void> setActorFavorite(VideoLink actor, bool favorite) async {
    await _prepareOnlineAccess();
    final base = _activeAccountBaseUrl;
    final generation = _sessionGeneration;
    final actorUri = _localizedSourceUri(actor.url);
    final (document: document, uri: _) = await _loadDocument(
      actorUri,
      generation,
    );
    final sourceId = _actorSourceId(document);
    if (sourceId == null) {
      throw MissavUnsupportedException(
        capability: 'actor favorites without a source actor ID',
        sourceUrl: actor.url,
      );
    }
    final viewUri = Uri.parse('$base/api/actresses/$sourceId/view');
    final viewResponse = await _request(viewUri, generation: generation);
    _checkGeneration(generation, viewUri);
    final viewBody = _decodeObject(viewResponse.data, viewUri);
    if (viewBody.containsKey('user')) {
      _updateAccountFromSource(viewBody['user']);
    }
    await _request(
      Uri.parse('$base/api/actresses/$sourceId/save'),
      method: favorite ? 'POST' : 'DELETE',
      generation: generation,
    );
  }

  Future<void> createPlaylist(String title) async =>
      throw MissavUnsupportedException(
        capability: 'creating a playlist',
        sourceUrl: collectionUrl('playlists'),
      );

  Future<void> renamePlaylist(VideoLink playlist, String title) async =>
      throw MissavUnsupportedException(
        capability: 'renaming a playlist',
        sourceUrl: playlist.url,
      );

  Future<void> deletePlaylist(VideoLink playlist) async =>
      throw MissavUnsupportedException(
        capability: 'deleting a playlist',
        sourceUrl: playlist.url,
      );

  Future<void> addToPlaylist(VideoLink playlist, VideoItem item) =>
      _setPlaylistMembership(playlist, item, added: true);

  Future<void> removeFromPlaylist(VideoLink playlist, VideoItem item) =>
      _setPlaylistMembership(playlist, item, added: false);

  Future<void> _setPlaylistMembership(
    VideoLink playlist,
    VideoItem item, {
    required bool added,
  }) async {
    await _prepareOnlineAccess();
    final base = _activeAccountBaseUrl;
    final key = playlist.sourceKey;
    if (key == null || key.isEmpty) {
      throw MissavUnsupportedException(
        capability: 'playlist action without a source playlist key',
        sourceUrl: playlist.url,
      );
    }
    await _request(
      Uri.parse('$base/api/playlists/${added ? 'add' : 'remove'}'),
      method: 'POST',
      data: {'dvdId': item.id, 'key': key},
    );
  }

  Future<void> clearWatchHistory() async {
    await _prepareOnlineAccess();
    await _request(
      Uri.parse('$_activeAccountBaseUrl/api/history'),
      method: 'DELETE',
    );
  }

  Future<({Document document, Uri uri})> _loadDocument(
    Uri target,
    int generation, {
    CancelToken? cancelToken,
    bool isContentPage = false,
    bool allowNotFound = false,
  }) async {
    var uri = target;
    _checkGeneration(generation, uri);
    final adapter = uri.origin == origin ? _browserAdapter : null;
    final String body;
    if (adapter is MissavBrowserAdapter) {
      try {
        body = await adapter.loadDocument(
          uri,
          cancelToken: cancelToken ?? _sessionCancelToken,
        );
      } on DioException catch (error) {
        _checkGeneration(generation, uri);
        if (error.error is MissavException) throw error.error!;
        if (error.type == DioExceptionType.cancel) rethrow;
        throw MissavException(
          'MissAV browser navigation failed (${error.type.name}).',
          sourceUrl: uri.toString(),
        );
      }
    } else {
      final response = await _request(
        uri,
        generation: generation,
        cancelToken: cancelToken,
        isContentPage: isContentPage,
        allowNotFound: allowNotFound,
      );
      body = response.data as String;
      if (isContentPage) uri = response.requestOptions.uri;
    }
    _checkGeneration(generation, uri);
    if (cancelToken?.cancelError case final error?) throw error;
    final document = _parsePage(body, uri);
    final responseStatus = document.querySelector(
      '#kiko-missav-response-status',
    );
    if (responseStatus != null) {
      final status = int.tryParse(responseStatus.text);
      responseStatus.remove();
      if (status == HttpStatus.unauthorized) {
        _updateAccountFromSource(null);
        throw MissavAuthenticationException(sourceUrl: uri.toString());
      }
      if (status != null && status >= 400) {
        throw allowNotFound && const {404, 410}.contains(status)
            ? _ContentPageMissing(
                'MissAV returned HTTP $status.',
                sourceUrl: uri.toString(),
              )
            : _responseFailure(status, uri);
      }
    }
    if (adapter is MissavBrowserAdapter && uri.origin == _sessionHost) {
      await _saveBrowserCookies(adapter, uri, generation);
      _checkGeneration(generation, uri);
      if (cancelToken?.cancelError case final error?) throw error;
    }
    final context = document.querySelector(
      '#kiko-missav-recommendation-context',
    );
    if (context != null) {
      context.remove();
      final data = jsonDecode(context.text);
      if (data is Map &&
          data['userId'] is String &&
          (data['userId'] as String).isNotEmpty &&
          const {
            'desktop-home-recommended',
            'mobile-home-recommended',
          }.contains(data['scenario'])) {
        _recommendationUserId = data['userId'] as String;
        _recommendationScenario = data['scenario'] as String;
      }
    }
    return (document: document, uri: uri);
  }

  Future<Response<dynamic>> _request(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int? generation,
    CancelToken? cancelToken,
    bool direct = false,
    bool isContentPage = false,
    bool allowNotFound = false,
    _MissavLoginCookies? login,
  }) async {
    if (generation == null) await _prepareOnlineAccess();
    final requestGeneration = generation ?? _sessionGeneration;
    final requestCancelToken = cancelToken ?? _sessionCancelToken;
    final isApi = uri.pathSegments.contains('api');
    var requestUri = isApi || direct || isContentPage
        ? _sourceUri(uri.toString())
        : _remapSource(_sourceUri(uri.toString()));
    var requestMethod = method;
    var requestData = data;

    for (var redirect = 0; redirect <= _pageLimit; redirect++) {
      _checkGeneration(requestGeneration, requestUri);
      if (requestCancelToken.cancelError case final error?) throw error;
      final headers = <String, dynamic>{
        'Accept': isApi
            ? 'application/json, text/plain, */*'
            : 'text/html,application/xhtml+xml,*/*',
        if (isApi) 'X-Requested-With': 'XMLHttpRequest',
        'User-Agent': _userAgent,
      };
      if (_isSource(requestUri)) {
        headers['Origin'] = requestUri.origin;
        headers['Referer'] = '${requestUri.origin}/';
        headers['Accept-Language'] = 'en-US,en;q=0.9';
        headers['Cache-Control'] = 'no-cache';
        final cookie = login != null
            ? (requestUri.origin == login.host ? login.cookies.header : null)
            : (requestUri.origin == _sessionHost ? _cookies.header : null);
        if (cookie != null && cookie.isNotEmpty) {
          headers['Cookie'] = cookie;
          final xsrfToken = _cookieValue(cookie, 'XSRF-TOKEN');
          if (xsrfToken != null) {
            headers['X-XSRF-TOKEN'] = Uri.decodeComponent(xsrfToken);
          }
        }
      }

      late final Response<dynamic> response;
      try {
        final dio = requestUri.origin == origin ? _browserDio ?? _dio : _dio;
        response = await dio.request<dynamic>(
          requestUri.toString(),
          data: requestData,
          cancelToken: requestCancelToken,
          options: Options(
            method: requestMethod,
            headers: headers,
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 600,
          ),
        );
      } on DioException catch (error) {
        _checkGeneration(requestGeneration, requestUri);
        if (error.type == DioExceptionType.cancel) rethrow;
        final wrappedError = error.error;
        if (wrappedError is MissavVerificationRequiredException) {
          throw wrappedError;
        }
        throw MissavException(
          'MissAV request failed (${error.response?.statusCode ?? error.type.name}).',
          sourceUrl: requestUri.toString(),
          cause: error,
        );
      }
      _checkGeneration(requestGeneration, requestUri);
      if (requestCancelToken.cancelError case final error?) throw error;

      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      final terminalContentStatus =
          isContentPage && const {401, 404, 410, 419}.contains(status);
      final mitigation = response.headers.value('cf-mitigated');
      if (mitigation?.trim().toLowerCase() == 'challenge' ||
          (mitigation == null &&
              !terminalContentStatus &&
              status != HttpStatus.tooManyRequests &&
              isChallengeResponse(response.data))) {
        if (_isMirrorHost(requestUri.host)) {
          throw MissavMirrorUnavailableException(
            challenged: true,
            sourceUrl: requestUri.toString(),
          );
        }
        throw MissavVerificationRequiredException(
          sourceUrl: requestUri.toString(),
        );
      }
      if (isContentPage && status >= 500) {
        throw _ContentHostFailure(
          'MissAV returned HTTP $status.',
          sourceUrl: requestUri.toString(),
        );
      }
      if (status >= 500 ||
          status == HttpStatus.forbidden ||
          status == HttpStatus.tooManyRequests) {
        throw _responseFailure(
          status,
          requestUri,
          retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
        );
      }
      if (allowNotFound && const {404, 410}.contains(status)) {
        throw _ContentPageMissing(
          'MissAV returned HTTP $status.',
          sourceUrl: requestUri.toString(),
        );
      }
      await _saveResponseCookies(
        response,
        requestUri,
        requestGeneration,
        login: login,
      );
      final browser = _browserAdapter;
      if (login == null &&
          isApi &&
          status >= 200 &&
          status < 300 &&
          requestUri.origin == origin &&
          requestUri.origin == _sessionHost &&
          browser is MissavBrowserAdapter) {
        await _saveBrowserCookies(browser, requestUri, requestGeneration);
      }
      _checkGeneration(requestGeneration, requestUri);
      if (requestCancelToken.cancelError case final error?) throw error;
      if (status >= 300 && status < 400 && location != null) {
        final redirectedUri = requestUri.resolve(location);
        if (!_isSource(redirectedUri)) {
          throw MissavUnsupportedException(
            capability: 'following a redirect outside MissAV',
            sourceUrl: redirectedUri.toString(),
          );
        }
        final accountRequestHost = login?.host ?? (isApi ? uri.origin : null);
        if (accountRequestHost != null &&
            redirectedUri.origin != accountRequestHost) {
          throw MissavException(
            'MissAV account request redirected to another host.',
            sourceUrl: requestUri.toString(),
          );
        }
        if (isContentPage &&
            missavMirrorDomain(redirectedUri.host) !=
                missavMirrorDomain(requestUri.host)) {
          throw _ContentHostFailure(
            'MissAV redirected the content page to another line.',
            sourceUrl: requestUri.toString(),
          );
        }
        requestUri =
            isContentPage && uri.hasFragment && !redirectedUri.hasFragment
            ? redirectedUri.replace(fragment: uri.fragment)
            : redirectedUri;
        if (status == 303 ||
            ((status == 301 || status == 302) && requestMethod != 'GET')) {
          requestMethod = 'GET';
          requestData = null;
        }
        continue;
      }
      if (status == HttpStatus.unauthorized) {
        if (login == null && requestUri.origin == _activeAccountBaseUrl) {
          _updateAccountFromSource(null);
        }
        throw MissavAuthenticationException(sourceUrl: requestUri.toString());
      }
      if (status < 200 || status >= 300) {
        throw _responseFailure(status, requestUri);
      }
      return response;
    }

    final sourceUrl = uri.toString();
    const message = 'MissAV redirected too many times.';
    throw isContentPage
        ? _ContentHostFailure(message, sourceUrl: sourceUrl)
        : MissavException(message, sourceUrl: sourceUrl);
  }

  static MissavException _responseFailure(
    int status,
    Uri uri, {
    String? retryAfter,
  }) => switch (status) {
    HttpStatus.forbidden => MissavAccessDeniedException(
      sourceUrl: uri.toString(),
    ),
    HttpStatus.tooManyRequests => MissavRateLimitException(
      sourceUrl: uri.toString(),
      retryAt: _retryAt(retryAfter),
    ),
    _ => MissavException('MissAV returned HTTP $status.', sourceUrl: '$uri'),
  };

  static DateTime? _retryAt(String? header) {
    final value = header?.trim();
    if (value == null || value.isEmpty) return null;
    try {
      if (RegExp(r'^\d+$').hasMatch(value)) {
        final seconds = int.tryParse(value);
        if (seconds == null) return null;
        return DateTime.now().add(Duration(seconds: seconds));
      }
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Future<void> _saveResponseCookies(
    Response<dynamic> response,
    Uri uri,
    int generation, {
    _MissavLoginCookies? login,
  }) async {
    final accountHost = login?.host ?? _activeAccountBaseUrl;
    if (uri.origin != accountHost || generation != _sessionGeneration) {
      return;
    }
    final values = response.headers['set-cookie'];
    if (values == null || values.isEmpty) return;
    if (login != null) {
      login.cookies = login.cookies.withResponse(values);
      return;
    }

    await _writeSession(generation, () async {
      if (accountHost != _activeAccountBaseUrl) return;
      final current = _sessionHost == accountHost
          ? _cookies
          : const _MissavCookies();
      final updated = current.withResponse(values);
      await _persistSession(
        generation,
        cookies: updated,
        userAgent: _userAgent,
        host: accountHost,
      );
      if (generation == _sessionGeneration) {
        _cookies = updated;
        _sessionHost = accountHost;
        if (updated.header == null) _userAgent = _defaultUserAgent;
      }
    });
  }

  Future<void> _saveBrowserCookies(
    MissavBrowserAdapter browser,
    Uri uri,
    int generation,
  ) async {
    final read = browser.readCookieHeader;
    if (read == null) return;
    await _writeSession(generation, () async {
      if (uri.origin != _sessionHost) return;
      final String header;
      try {
        header = await read();
        _validateHeaderValue(header, 'cookieHeader');
      } catch (_) {
        return;
      }
      if (generation != _sessionGeneration || header == _cookies.header) return;
      final updated = _cookies.withBrowserHeader(header);
      try {
        await _persistSession(
          generation,
          cookies: updated,
          userAgent: _userAgent,
          host: uri.origin,
        );
      } catch (_) {
        debugPrint('MissAV could not persist browser cookies.');
        return;
      }
      if (generation == _sessionGeneration) _cookies = updated;
    });
  }

  Future<void> _persistSession(
    int generation, {
    required _MissavCookies cookies,
    required String userAgent,
    required String host,
  }) async {
    final cookie = cookies.header;
    if (cookie == null) {
      await _secureStorage.delete(key: _sessionRecordKey);
      if (generation == _sessionGeneration) {
        await _secureStorage.delete(key: _cookieKey);
      }
      return;
    }

    await _secureStorage.write(
      key: _sessionRecordKey,
      value: jsonEncode({
        'cookie': cookie,
        'userAgent': userAgent,
        'host': host,
        if (cookies.expirations.isNotEmpty) 'expires': cookies.expirations,
      }),
    );
    if (generation != _sessionGeneration) return;
    await _secureStorage.write(key: _cookieKey, value: cookie);
  }

  Future<void> _writeSession(
    int generation,
    Future<void> Function() write,
  ) async {
    final previous = _pendingSessionWrite;
    final completed = Completer<void>();
    _pendingSessionWrite = completed.future;
    await previous;
    try {
      if (generation == _sessionGeneration) await write();
    } finally {
      completed.complete();
    }
  }

  Future<void> _clearSession(int generation) async {
    if (generation != _sessionGeneration) return;
    final accountChanged = _isLoggedIn || _accountName != null;
    _cookies = const _MissavCookies();
    _sessionHost = null;
    _confirmedGuest = true;
    _userAgent = _defaultUserAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();
    await _writeSession(generation, () async {
      await _secureStorage.delete(key: _sessionRecordKey);
      await _secureStorage.delete(key: _cookieKey);
    });
  }

  static ({_MissavCookies cookies, String userAgent, String? host})?
  _decodeStoredSession(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map &&
          decoded['cookie'] is String &&
          decoded['userAgent'] is String) {
        final cookie = decoded['cookie'] as String;
        final userAgent = decoded['userAgent'] as String;
        _validateHeaderValue(cookie, 'cookie');
        _validateHeaderValue(userAgent, 'userAgent');
        final host = decoded['host'];
        if (host != null && !accountHosts.contains(host)) return null;
        return (
          cookies: _MissavCookies.fromHeader(cookie, decoded['expires']),
          userAgent: userAgent,
          host: host as String?,
        );
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    return null;
  }

  static void _validateHeaderValue(String value, String name) {
    if (value.trim().isEmpty ||
        value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      throw ArgumentError.value(value, name, 'must be a valid HTTP header');
    }
  }

  static String? _cookieValue(String? header, String name) {
    for (final pair in (header ?? '').split(';')) {
      final separator = pair.indexOf('=');
      if (separator > 0 && pair.substring(0, separator).trim() == name) {
        return pair.substring(separator + 1).trim();
      }
    }
    return null;
  }

  void _setAccountState({required bool loggedIn, bool notify = true}) {
    if (loggedIn) {
      _confirmedGuest = false;
      cancelBackgroundMirrorProbe();
    }
    if (_isLoggedIn == loggedIn) return;
    _isLoggedIn = loggedIn;
    if (notify && !_disposed) notifyListeners();
  }

  int _advanceSessionGeneration() {
    _accountRestore = null;
    cancelBackgroundMirrorProbe();
    _recommendationUserId = null;
    _recommendationScenario = null;
    _searches.clear();
    _sessionCancelToken.cancel('MissAV account changed.');
    for (final cancelToken in _browseCancelTokens.toList()) {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('MissAV account changed.');
      }
    }
    _sessionCancelToken = CancelToken();
    return ++_sessionGeneration;
  }

  void _checkGeneration(int generation, Uri uri) {
    if (_disposed || generation != _sessionGeneration) {
      throw MissavException(
        'MissAV account changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
  }

  void _checkCancelled(CancelToken? cancelToken, Uri uri) {
    if (cancelToken?.cancelError case final error?) throw error;
  }

  static Uri _sourceUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !_isSource(uri)) {
      throw MissavUnsupportedException(
        capability: 'opening a non-MissAV page in the native client',
        sourceUrl: url,
      );
    }
    return uri;
  }

  static bool _isSource(Uri uri) =>
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      _sourceDomains.any(
        (domain) =>
            uri.host.toLowerCase() == domain ||
            uri.host.toLowerCase().endsWith('.$domain'),
      );

  static bool _isMirrorHost(String host) =>
      _mirrorHosts.any((mirror) => host == mirror || host.endsWith('.$mirror'));

  static const _legacyMirrorHost = 'thisav66.com';

  Uri _remapSource(Uri uri, {String? baseUrl}) {
    if (!_isSource(uri)) return uri;
    final base = Uri.parse(baseUrl ?? _baseUrl);
    if (uri.host == base.host) return uri;
    if (base.origin == origin &&
        uri.host != _legacyMirrorHost &&
        !uri.host.endsWith('.$_legacyMirrorHost')) {
      return uri;
    }
    return base.replace(
      path: uri.path.isEmpty ? '/' : uri.path,
      query: uri.hasQuery ? uri.query : null,
      fragment: uri.hasFragment ? uri.fragment : null,
    );
  }

  static const _sourceLanguages = {
    'cn',
    'zh',
    'ja',
    'en',
    'ko',
    'ms',
    'th',
    'de',
    'fr',
    'vi',
    'id',
    'fil',
    'pt',
  };

  Uri? _accountPageUri(Uri uri) {
    final segments = uri.pathSegments;
    final path = RegExp(r'^dm\d+$').hasMatch(segments.firstOrNull ?? '')
        ? segments.skip(1)
        : segments;
    final route = path.skipWhile(_sourceLanguages.contains).firstOrNull;
    if (!const {'saved', 'playlists', 'history'}.contains(route)) return null;
    return uri.replace(
      host: Uri.parse(_activeAccountBaseUrl).host,
      pathSegments: path,
    );
  }

  String get _localePrefix => _locale == 'zh' ? '' : '/$_locale';

  static String? _searchQuery(Uri uri) {
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final index =
        segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)
        ? 1
        : 0;
    final hasLocale =
        segments.length > index && _sourceLanguages.contains(segments[index]);
    final route = index + (hasLocale ? 1 : 0);
    return segments.length > route + 1 && segments[route] == 'search'
        ? segments[route + 1]
        : null;
  }

  Uri _localizedSourceUri(String url, {bool remap = true}) {
    final source = _sourceUri(url);
    final uri = remap ? _remapSource(source) : source;
    final segments = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final index =
        segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)
        ? 1
        : 0;
    final hasLocale =
        segments.length > index && _sourceLanguages.contains(segments[index]);
    final routeIndex = index + (hasLocale ? 1 : 0);
    // Genre slugs only select the right category in their source language.
    if (segments.length == routeIndex + 2 && segments[routeIndex] == 'genres') {
      return uri;
    }
    if (hasLocale) {
      segments.removeAt(index);
    }
    if (_locale != 'zh') segments.insert(index, _locale);
    return uri.replace(pathSegments: segments);
  }

  static Document _parsePage(String source, Uri uri) {
    if (isChallengeResponse(source)) {
      throw MissavVerificationRequiredException(sourceUrl: uri.toString());
    }
    return html_parser.parse(source);
  }

  static bool isChallengeResponse(Object? body) {
    if (body is! String) return false;
    final lower = body.toLowerCase();
    final title = RegExp(
      r'<title[^>]*>(.*?)</title>',
      dotAll: true,
    ).firstMatch(lower)?.group(1)?.trim();
    if (title != null &&
        (title.startsWith('just a moment') ||
            (title.contains('attention required') &&
                title.contains('cloudflare')))) {
      return true;
    }
    if (RegExp(r'\bwindow\s*\.\s*_cf_chl_opt\b').hasMatch(lower)) {
      return true;
    }
    final hasChallengeForm = RegExp(
      r"""<form\b[^>]*\bid=["']challenge-form["'][^>]*>""",
    ).hasMatch(lower);
    final hasChallengeAction = RegExp(
      r"""<form\b[^>]*\baction=["'][^"']*/cdn-cgi/challenge-platform/""",
    ).hasMatch(lower);
    final hasCaptchaAction = RegExp(
      r"""<form\b[^>]*\baction=["'][^"']*/cdn-cgi/l/chk_captcha""",
    ).hasMatch(lower);
    if (hasChallengeForm || hasChallengeAction || hasCaptchaAction) {
      return true;
    }
    return lower.contains('orchestrate') && lower.contains('chl_page');
  }

  void _updateHomeUrl(Document document, Uri pageUri) {
    for (final anchor in document.querySelectorAll('nav a[href]')) {
      final href = anchor.attributes['href'];
      if (href == null) continue;
      final candidate = pageUri.resolve(href);
      if (!_isSource(candidate)) continue;
      final segments = candidate.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.isNotEmpty && RegExp(r'^dm\d+$').hasMatch(segments.first)) {
        segments.removeAt(0);
      }
      if ((_locale == 'zh' && segments.isEmpty) ||
          (segments.length == 1 && segments.single == _locale)) {
        _homeUrl = candidate.toString();
        return;
      }
    }
  }

  static String? _accountNameFrom(Map<String, dynamic> user) {
    for (final key in const ['email', 'username', 'name']) {
      final value = user[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  Map<String, dynamic> _decodeObject(Object? value, Uri uri) {
    try {
      final decoded = value is String ? jsonDecode(value) : value;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException catch (error) {
      throw MissavException(
        'MissAV returned an invalid response.',
        sourceUrl: uri.toString(),
        cause: error,
      );
    }
    throw MissavException(
      'MissAV returned an invalid response.',
      sourceUrl: uri.toString(),
    );
  }

  void _updateAccountFromSource(Object? sourceUser) {
    final previousName = _accountName;
    final previousLoginState = _isLoggedIn;
    if (sourceUser is Map) {
      _accountName = _accountNameFrom(Map<String, dynamic>.from(sourceUser));
      _setAccountState(loggedIn: true, notify: false);
    } else if (sourceUser == null) {
      _confirmedGuest = true;
      _accountName = null;
      _setAccountState(loggedIn: false, notify: false);
    } else {
      return;
    }
    if (previousName != _accountName || previousLoginState != _isLoggedIn) {
      if (!_disposed) notifyListeners();
    }
  }

  void _updateAccountFromPage(Document document, Uri uri) {
    if (!_officialHosts.contains(uri.host) ||
        (_sessionHost != null && uri.origin != _activeAccountBaseUrl)) {
      return;
    }
    final sourceUser = _readAccountFromPage(document);
    // Public user:null markup needs runtime state or /view to confirm sign-in.
    if (sourceUser != null) {
      _updateAccountFromSource(sourceUser);
    }
  }

  static Map<String, dynamic>? readAccountFromMarkup(String source, Uri uri) =>
      _readAccountFromPage(_parsePage(source, uri));

  static Map<String, dynamic>? _readAccountFromPage(Document document) {
    final runtimeUser = document.querySelector('#kiko-missav-runtime-user');
    if (runtimeUser != null) {
      try {
        final user = jsonDecode(runtimeUser.text);
        if (user is Map<String, dynamic>) return user;
      } on FormatException {
        // Fall back to page markup if the runtime snapshot is invalid.
      }
    }
    for (final element in document.querySelectorAll('[x-data]')) {
      final source = element.attributes['x-data'] ?? '';
      final match = RegExp(
        r'''(?:^|[{,])\s*(?:user|"user"|'user')\s*:\s*\{([^}]*)\}''',
      ).firstMatch(source);
      if (match == null) continue;
      final fields = match.group(1)!.trim();
      if (fields.isEmpty) return null;
      return {
        for (final property in RegExp(
          r'''['"]?(email|username|name)['"]?\s*:\s*(['"])(.*?)\2''',
        ).allMatches(fields))
          property.group(1)!: property.group(3),
      };
    }
    return null;
  }

  static String? _sourceId(Document document) {
    for (final element in document.querySelectorAll(
      'script, [x-init], [x-data]',
    )) {
      final source = '${element.text} ${element.attributes.values.join(' ')}';
      final match = RegExp(
        r'''/api/items/([A-Za-z0-9_-]+)/(?:save|view)\b''',
      ).firstMatch(source);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static String? _actorSourceId(Document document) {
    for (final element in document.querySelectorAll(
      'script, [x-init], [x-data]',
    )) {
      final source = '${element.text} ${element.attributes.values.join(' ')}';
      final match = RegExp(
        r'''/api/actresses/(\d+)/(?:save|view)\b''',
      ).firstMatch(source);
      if (match != null) return match.group(1);
    }
    return null;
  }

  static bool? _savedState(Document document) {
    for (final element in document.querySelectorAll('[x-data]')) {
      final source = element.attributes['x-data'] ?? '';
      final match = RegExp(r'\bsaved\s*:\s*(true|false)\b').firstMatch(source);
      if (match != null) return match.group(1) == 'true';
    }
    return null;
  }

  static String _parseDescription(Document document) {
    final sourceDescription = document
        .querySelector(
          '[x-data*="showMore"] .mb-1.text-secondary.break-all.line-clamp-2',
        )
        ?.text
        .trim();
    if (sourceDescription?.isNotEmpty == true) return sourceDescription!;
    return document.querySelector('[itemprop="description"]')?.text.trim() ??
        document
            .querySelector('meta[name="description"]')
            ?.attributes['content']
            ?.trim() ??
        '';
  }

  static Map<String, String> _parseMetadata(
    Document document,
    Uri pageUri,
    List<VideoLink> displayedLinks,
    VideoItem video,
  ) {
    final metadata = <String, String>{};
    final displayedUrls = displayedLinks.map((link) => link.url).toSet();
    for (final row in _detailMetadataRows(document)) {
      final labelElement = row.querySelector('span');
      if (labelElement == null) continue;
      final label = _metadataLabel(labelElement);
      final value = row.nodes
          .where((node) => node != labelElement)
          .map((node) => node.text)
          .join()
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (_metadataRowIsFullyDisplayed(row, value, pageUri, displayedUrls) ||
          _metadataValueIsDisplayed(label, value, video)) {
        continue;
      }
      if (label.isNotEmpty && value.isNotEmpty) metadata[label] = value;
    }
    return metadata;
  }

  static Map<String, String> _metadataWithoutVideoGroups(
    Map<String, String> metadata,
    VideoItem video,
  ) => {
    for (final entry in metadata.entries)
      if (!_metadataValueIsDisplayed(entry.key, entry.value, video))
        entry.key: entry.value,
  };

  static const detailMetadataGroups = {
    'genre': 'genres',
    'genres': 'genres',
    'category': 'genres',
    'categories': 'genres',
    'tag': 'genres',
    'tags': 'genres',
    'ジャンル': 'genres',
    '类型': 'genres',
    '類型': 'genres',
    '类别': 'genres',
    '類別': 'genres',
    '分类': 'genres',
    '分類': 'genres',
    'maker': 'makers',
    'makers': 'makers',
    'manufacturer': 'makers',
    'manufacturers': 'makers',
    'studio': 'makers',
    'studios': 'makers',
    'メーカー': 'makers',
    '厂商': 'makers',
    '廠商': 'makers',
    'label': 'labels',
    'labels': 'labels',
    'brand': 'labels',
    'brands': 'labels',
    'レーベル': 'labels',
    '品牌': 'labels',
    '系列': 'series',
    'series': 'series',
    'シリーズ': 'series',
    'director': 'directors',
    'directors': 'directors',
    '監督': 'directors',
    '导演': 'directors',
    '導演': 'directors',
    'actor': 'actors',
    'actors': 'actors',
    'actress': 'actors',
    'actresses': 'actors',
    'cast': 'actors',
    '出演者': 'actors',
    '演员': 'actors',
    '演員': 'actors',
    '女优': 'actors',
    '女優': 'actors',
  };

  static bool _metadataValueIsDisplayed(
    String label,
    String value,
    VideoItem video,
  ) {
    final group = detailMetadataGroups[label.toLowerCase()];
    if (group == null) return false;
    final names = switch (group) {
      'genres' => video.cardTags.map((tag) => tag.label),
      'makers' => video.cardMakers,
      'labels' => video.cardLabels,
      'series' => video.cardSeries,
      'directors' => video.cardDirectors,
      'actors' => video.actors.map((actor) => actor.label),
      _ => const <String>[],
    };
    final displayedNames =
        names
            .map((name) => name.trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    if (displayedNames.isEmpty) return false;
    var remaining = value.trim();
    while (remaining.isNotEmpty) {
      String? name;
      for (final candidate in displayedNames) {
        if (remaining.startsWith(candidate)) {
          name = candidate;
          break;
        }
      }
      if (name == null) return false;
      remaining = remaining.substring(name.length);
      if (remaining.isNotEmpty) {
        final separator = RegExp(
          r'^[\s,，、;；|/·•&+＋()（）\[\]{}\-–—]+',
        ).matchAsPrefix(remaining);
        if (separator == null) return false;
        remaining = remaining.substring(separator.end);
      }
    }
    return true;
  }

  static bool _metadataRowIsFullyDisplayed(
    Element row,
    String value,
    Uri pageUri,
    Set<String> displayedUrls,
  ) {
    final anchors = row.querySelectorAll('a[href]');
    if (anchors.isEmpty) return false;
    var remaining = value;
    for (final anchor in anchors) {
      final href = anchor.attributes['href'];
      if (href == null ||
          !displayedUrls.contains(pageUri.resolve(href).toString())) {
        return false;
      }
      final label = anchor.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (label.isEmpty) return false;
      final index = remaining.indexOf(label);
      if (index < 0) return false;
      remaining = remaining.replaceRange(index, index + label.length, '');
    }
    return remaining
        .replaceAll(RegExp(r'[\s,，、;；|/·•:：&+＋()（）\[\]{}\-–—]+'), '')
        .isEmpty;
  }

  static Iterable<Element> _detailMetadataRows(Document document) =>
      document.querySelectorAll('div.text-secondary').where((row) {
        final label = row.children.isEmpty ? null : row.children.first;
        return label?.localName == 'span' &&
            RegExp(r'[:：]$').hasMatch(label!.text.trim());
      });

  static String _metadataLabel(Element element) =>
      element.text.trim().replaceAll(RegExp(r'[:：]$'), '').trim();

  static List<VideoLink> _parseDetailLinks(
    Document document,
    Uri pageUri,
    VideoLinkKind kind,
  ) {
    final seen = <String>{};
    final links = <VideoLink>[];
    for (final row in _detailMetadataRows(document)) {
      for (final anchor in row.querySelectorAll('a[href]')) {
        final href = anchor.attributes['href'];
        if (href == null) continue;
        final uri = pageUri.resolve(href);
        if (!_isSource(uri) || uri == pageUri || !seen.add(uri.toString())) {
          continue;
        }
        final label = anchor.text.trim();
        if (label.isEmpty) continue;
        final route = uri.path.toLowerCase();
        final isActor =
            route.contains('/actresses/') || route.contains('/actors/');
        final isTag =
            route.contains('/category') ||
            route.contains('/genre') ||
            route.contains('/tag') ||
            route.contains('/studio') ||
            route.contains('/label') ||
            route.contains('/maker') ||
            route.contains('/director') ||
            route.contains('/series');
        if (kind == VideoLinkKind.actor && !isActor) continue;
        if (kind == VideoLinkKind.tag && (!isTag || isActor)) continue;
        links.add(
          VideoLink(
            label: label,
            url: uri.toString(),
            kind: isActor ? VideoLinkKind.actor : _detailLinkKind(route),
          ),
        );
      }
    }
    return links;
  }

  static VideoLinkKind _detailLinkKind(String route) {
    if (route.contains('/genre') ||
        route.contains('/category') ||
        route.contains('/tag') ||
        route.contains('/label') ||
        route.contains('/series')) {
      return VideoLinkKind.category;
    }
    if (route.contains('/maker') || route.contains('/studio')) {
      return VideoLinkKind.studio;
    }
    return VideoLinkKind.other;
  }

  static List<VideoStream> _parseStreams(
    Document document,
    Uri pageUri, {
    required String userAgent,
  }) {
    final streams = <VideoStream>[];
    final urls = <String>{};
    for (final script in document.querySelectorAll('script')) {
      final text = _unpackPacker(script.text);
      if (text == null) continue;
      for (final match in RegExp(
        r'''\b(source\d*)\s*=\s*(['"])(.*?)\2''',
        dotAll: true,
      ).allMatches(text)) {
        final name = match.group(1)!;
        var url = match.group(3)!.replaceAll(r'\/', '/');
        final source = Uri.tryParse(url);
        if (_isMirrorHost(pageUri.host) &&
            source != null &&
            source.host.isNotEmpty) {
          url =
              '${pageUri.origin}/jmpres/${source.host}${source.path}'
              '${source.hasQuery ? '?${source.query}' : ''}';
        }
        final uri = Uri.tryParse(url);
        if (uri == null ||
            (uri.scheme != 'https' && uri.scheme != 'http') ||
            uri.host.isEmpty ||
            !RegExp(
              r'\.(m3u8|mp4)$',
              caseSensitive: false,
            ).hasMatch(uri.path) ||
            !urls.add(uri.toString())) {
          continue;
        }
        streams.add(
          VideoStream(
            label: name == 'source' ? 'Source' : 'Source ${name.substring(6)}',
            url: uri.toString(),
            headers: {
              HttpHeaders.refererHeader: pageUri.toString(),
              'Origin': pageUri.origin,
              HttpHeaders.userAgentHeader: userAgent,
            },
            isHls: uri.path.toLowerCase().endsWith('.m3u8'),
          ),
        );
      }
    }
    return streams;
  }

  // Expands the packed token table without evaluating page JavaScript.
  static String? _unpackPacker(String source) {
    final match = RegExp(
      r'''eval\(function\(p,a,c,k,e,d\).*?\}\('((?:\\.|[^'])*)',\s*(\d+),\s*(\d+),\s*'((?:\\.|[^'])*)'\.split\('\|'\)''',
      dotAll: true,
    ).firstMatch(source);
    if (match == null) return null;
    final payload = match.group(1)!.replaceAll(r"\'", "'");
    final radix = int.parse(match.group(2)!);
    if (radix < 2 || radix > 62) return null;
    final count = int.parse(match.group(3)!);
    final words = match.group(4)!.split('|');
    final replacements = <String, String>{
      for (var index = 0; index < count && index < words.length; index++)
        if (words[index].isNotEmpty) _encodeRadix(index, radix): words[index],
    };
    return payload.replaceAllMapped(
      RegExp(r'\b\w+\b'),
      (token) => replacements[token[0]] ?? token[0]!,
    );
  }

  static String _encodeRadix(int value, int radix) {
    const digits =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    if (value == 0) return '0';
    var remainder = value;
    final result = StringBuffer();
    while (remainder > 0) {
      result.write(digits[remainder % radix]);
      remainder ~/= radix;
    }
    return result.toString().split('').reversed.join();
  }

  static String _pageTitle(Document document) {
    final heading =
        (document.querySelector('main h1') ?? document.querySelector('h1'))
            ?.text
            .trim();
    return heading?.isNotEmpty == true
        ? heading!
        : document.querySelector('title')?.text.trim() ?? '';
  }

  static List<VideoItem> _parseVideos(Document document, Uri pageUri) {
    final seen = <String>{};
    final videos = <VideoItem>[];
    for (final card in document.querySelectorAll(
      'div.relative.aspect-w-16.aspect-h-9',
    )) {
      final anchor = card.querySelector('a[href]');
      final image = card.querySelector('img[alt]');
      if (anchor == null || image == null) continue;
      final href = anchor.attributes['href'];
      final title = image.attributes['alt']?.trim() ?? '';
      if (href == null || title.isEmpty) continue;
      final itemUri = pageUri.resolve(href).removeFragment();
      if (!_isSource(itemUri) ||
          itemUri == pageUri.removeFragment() ||
          _collectionEntryKind(itemUri) != null) {
        continue;
      }
      final id = itemUri.pathSegments.isEmpty ? '' : itemUri.pathSegments.last;
      if (id.isEmpty || !seen.add(id)) continue;
      final dataCover = image.attributes['data-src'];
      final sourceCover = image.attributes['src'] ?? '';
      final cover = dataCover?.isNotEmpty == true
          ? pageUri.resolve(dataCover!).toString()
          : sourceCover.startsWith('data:')
          ? ''
          : sourceCover.isEmpty
          ? ''
          : pageUri.resolve(sourceCover).toString();
      final parent = card.parent;
      final information =
          parent != null &&
              parent.localName == 'div' &&
              parent.querySelector('h1, video') == null &&
              parent
                      .querySelectorAll('div.relative.aspect-w-16.aspect-h-9')
                      .length ==
                  1
          ? parent
          : card;
      final links = _parseCardLinks(information, pageUri);
      final badgeLabels = card
          .querySelectorAll('.bottom-1.left-1, [title], [aria-label]')
          .map(
            (element) =>
                '${element.text} ${element.attributes['title'] ?? ''} ${element.attributes['aria-label'] ?? ''}',
          )
          .join(' ');
      final labels =
          '${itemUri.path} $badgeLabels ${links.map((link) => link.label).join(' ')}';

      videos.add(
        VideoItem(
          id: id,
          title: title,
          pageUrl: itemUri.toString(),
          cover: cover,
          durationSeconds: _durationSeconds(
            card.querySelector('span.bottom-1.right-1')?.text.trim(),
          ),
          releaseDate: _releaseDate(information.querySelectorAll('time')),
          actors: links
              .where((link) => link.kind == VideoLinkKind.actor)
              .toList(),
          tags: links
              .where((link) => link.kind != VideoLinkKind.actor)
              .toList(),
          hasSubtitles: _hasSubtitleLabel(labels),
          isUncensored: _hasUncensoredLabel(labels),
        ),
      );
    }
    return videos;
  }

  static List<VideoLink> _parseCardLinks(Element card, Uri pageUri) {
    final seen = <String>{};
    final links = <VideoLink>[];
    for (final anchor in card.querySelectorAll('a[href]')) {
      final uri = pageUri.resolve(anchor.attributes['href']!).removeFragment();
      final kind = _browseLinkKind(uri);
      final label = anchor.text.trim();
      if (!_isSource(uri) ||
          label.isEmpty ||
          !const {
            VideoLinkKind.actor,
            VideoLinkKind.category,
            VideoLinkKind.tag,
            VideoLinkKind.studio,
          }.contains(kind) ||
          !seen.add(uri.toString())) {
        continue;
      }
      links.add(VideoLink(label: label, url: uri.toString(), kind: kind));
    }
    return links;
  }

  static String? _releaseDate(Iterable<Element> times) {
    for (final time in times) {
      final value = time.attributes['datetime'] ?? time.text.trim();
      if (DateTime.tryParse(value) != null && value.length >= 10) {
        return value.substring(0, 10);
      }
    }
    return null;
  }

  static bool _hasSubtitleLabel(String value) =>
      RegExp(r'字幕|subtitles?|subtitled', caseSensitive: false).hasMatch(value);

  static bool _hasUncensoredLabel(String value) =>
      RegExp(r'无码|無碼|無修正|uncensored', caseSensitive: false).hasMatch(value);

  List<VideoLink> _parseNavigation(Document document, Uri pageUri) {
    final seen = <String>{};
    return document
        .querySelectorAll('nav a[href]')
        .map((anchor) {
          final url = anchor.attributes['href'];
          if (url == null || url.startsWith('#')) return null;
          final label = anchor.text.trim();
          if (label.isEmpty) return null;
          final uri = pageUri.resolve(url).removeFragment();
          if (!_isSource(uri) ||
              _excludeDirectoryAnchor(anchor, uri) ||
              !seen.add(uri.toString())) {
            return null;
          }
          return VideoLink(
            label: label,
            url: uri.toString(),
            kind: VideoLinkKind.navigation,
          );
        })
        .whereType<VideoLink>()
        .toList();
  }

  static List<VideoLink> _parseLinks(Document document, Uri pageUri) {
    final seen = <String>{};
    final videoUrls = document
        .querySelectorAll('div.relative.aspect-w-16.aspect-h-9 a[href]')
        .map(
          (anchor) =>
              pageUri.resolve(anchor.attributes['href']!).removeFragment(),
        )
        .where((uri) => _collectionEntryKind(uri) == null)
        .map((uri) => uri.toString())
        .toSet();
    final navigationAnchors = document.querySelectorAll('nav a[href]').toSet();
    final links = <VideoLink>[];
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (navigationAnchors.contains(anchor) || _isLanguageAnchor(anchor)) {
        continue;
      }
      final href = anchor.attributes['href'];
      if (href == null || href.startsWith('#')) continue;
      final uri = pageUri.resolve(href).removeFragment();
      if (!_isSource(uri) || uri == pageUri) {
        continue;
      }
      if (_excludeDirectoryAnchor(anchor, uri)) continue;
      if (videoUrls.contains(uri.toString())) continue;
      final image = anchor.querySelector('img');
      final label = anchor.text.trim().isNotEmpty
          ? anchor.text.trim()
          : image?.attributes['alt']?.trim() ?? '';
      if (label.isEmpty || !seen.add(uri.toString())) continue;
      final imageSource =
          image?.attributes['data-src'] ?? image?.attributes['src'] ?? '';
      final cover = imageSource.isEmpty || imageSource.startsWith('data:')
          ? ''
          : pageUri.resolve(imageSource).toString();
      links.add(
        VideoLink(
          label: label,
          url: uri.toString(),
          cover: cover,
          kind: _collectionEntryKind(uri) ?? _browseLinkKind(uri),
        ),
      );
    }
    return links;
  }

  static bool _hasAccountDirectory(Document document, Uri uri) {
    final path = uri.pathSegments.where((part) => part.isNotEmpty).toList();
    final kind = switch (path.reversed.toList()) {
      ['actresses', 'saved', ...] => VideoLinkKind.actor,
      ['playlists', ...] => VideoLinkKind.playlist,
      _ => null,
    };
    return kind != null &&
        _parseLinks(
          document,
          uri,
        ).any((link) => _collectionEntryKind(Uri.parse(link.url)) == kind);
  }

  static VideoLinkKind? _collectionEntryKind(Uri uri) {
    final path = uri.pathSegments
        .where((part) => part.isNotEmpty)
        .skipWhile(
          (part) =>
              _sourceLanguages.contains(part) ||
              RegExp(r'^dm\d+$').hasMatch(part),
        );
    return switch (path.toList(growable: false)) {
      ['actresses' || 'actors', String actor] when actor != 'ranking' =>
        VideoLinkKind.actor,
      ['playlists', String key] when key != 'create' => VideoLinkKind.playlist,
      _ => null,
    };
  }

  static bool _isLanguageAnchor(Element anchor) {
    if (anchor.attributes.containsKey('hreflang') ||
        (anchor.attributes[':href'] ?? '').contains('localizedUrl(') ||
        (anchor.attributes['x-bind:href'] ?? '').contains('localizedUrl(')) {
      return true;
    }
    final label = anchor.text.trim().toLowerCase();
    return const {
      '简体中文',
      '簡體中文',
      '繁体中文',
      '繁體中文',
      'english',
      '日本語',
      '한국의',
      '한국어',
      'melayu',
      'ไทย',
      'deutsch',
      'français',
      'tiếng việt',
      'bahasa indonesia',
      'filipino',
      'português',
    }.contains(label);
  }

  static bool _excludeDirectoryAnchor(Element anchor, Uri uri) {
    final label = anchor.text.trim().toLowerCase();
    final relations = (anchor.attributes['rel'] ?? '').split(' ');
    final route = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .skipWhile(
          (segment) =>
              _sourceLanguages.contains(segment) ||
              RegExp(r'^dm\d+$').hasMatch(segment),
        )
        .join('/');
    return _isLanguageAnchor(anchor) ||
        const {'ads', 'contact', 'terms', 'upload'}.contains(route) ||
        _pageNumber(uri) != null ||
        relations.any(const {'next', 'prev', 'first', 'last'}.contains) ||
        RegExp(r'\bvip\b').hasMatch(label) ||
        RegExp(
          r'/(vip|premium|subscription|upgrade)(/|$)',
        ).hasMatch(uri.path) ||
        RegExp(r'/(actresses|actors)/ranking(/|$)').hasMatch(uri.path);
  }

  static int? _pageNumber(Uri uri) {
    final page = int.tryParse(uri.queryParameters['page'] ?? '');
    return page != null && page > 0 ? page : null;
  }

  static int? _jumpMaxPage(Document document, Uri pageUri) {
    int? maximum;
    final prefix = RegExp(r'^/dm\d+(?=/|$)');
    final path = pageUri.path.replaceFirst(prefix, '');
    final sourceQuery = Map<String, String>.of(pageUri.queryParameters)
      ..remove('page');
    for (final anchor in document.querySelectorAll('a[href]')) {
      final uri = pageUri.resolve(anchor.attributes['href']!);
      if (!_isSource(uri) || uri.path.replaceFirst(prefix, '') != path) {
        continue;
      }
      final targetQuery = Map<String, String>.of(uri.queryParameters)
        ..remove('page');
      if (!mapEquals(sourceQuery, targetQuery)) continue;
      final page = _pageNumber(uri);
      if (page != null && (maximum == null || page > maximum)) maximum = page;
    }
    final current = _pageNumber(pageUri) ?? 1;
    return maximum == null ? null : (maximum < current ? current : maximum);
  }

  static VideoLinkKind _browseLinkKind(Uri uri) {
    final route = uri.path.toLowerCase();
    if (route.contains('/playlists')) return VideoLinkKind.playlist;
    if (route.contains('/actresses') || route.contains('/actors')) {
      return VideoLinkKind.actor;
    }
    if (route.contains('/maker') || route.contains('/studio')) {
      return VideoLinkKind.studio;
    }
    if (route.contains('/category') ||
        route.contains('/genre') ||
        route.contains('/tag') ||
        route.contains('/director') ||
        route.contains('/label') ||
        route.contains('/series')) {
      return VideoLinkKind.category;
    }
    if (RegExp(r'/(saved|favorites|history)(/|$)').hasMatch(route)) {
      return VideoLinkKind.collection;
    }
    return VideoLinkKind.other;
  }

  static String? _paginationUrl(
    Document document,
    Uri pageUri,
    String direction,
  ) {
    Element? candidate = document.querySelector('a[rel="$direction"][href]');
    if (candidate == null) {
      for (final link in document.querySelectorAll('a[href]')) {
        final label = link.text.trim().toLowerCase();
        final aria = link.attributes['aria-label']?.toLowerCase() ?? '';
        final matches = direction == 'next'
            ? const {'next', '›', '»', '下一页', '下一頁', '次へ'}.contains(label) ||
                  aria.contains('next')
            : const {
                    'previous',
                    'prev',
                    '‹',
                    '«',
                    '上一页',
                    '上一頁',
                    '前へ',
                  }.contains(label) ||
                  aria.contains('previous') ||
                  aria.contains('prev');
        if (matches) {
          candidate = link;
          break;
        }
      }
    }
    final href = candidate?.attributes['href'];
    if (href == null) return null;
    final uri = pageUri.resolve(href);
    return _isSource(uri) ? uri.toString() : null;
  }

  static int? _durationSeconds(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final numbers = parts.map(int.tryParse).toList();
    if (numbers.any((part) => part == null || part < 0)) return null;
    final minutes = numbers[numbers.length - 2]!;
    final seconds = numbers.last!;
    if (minutes > 59 || seconds > 59) return null;
    if (parts.length == 2) return minutes * 60 + seconds;
    return numbers.first! * 3600 + minutes * 60 + seconds;
  }

  static BaseOptions _defaultOptions() => BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    sendTimeout: const Duration(seconds: 20),
  );

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _advanceSessionGeneration();
    _browserDio?.close(force: true);
    _browserDio = null;
    _mediaRoute = null;
    _dio.close(force: true);
    _metadataDio.close(force: true);
    super.dispose();
  }
}

class _MissavLoginCookies {
  _MissavLoginCookies(this.host, this.cookies);

  final String host;
  _MissavCookies cookies;
}

class _MissavCookies {
  const _MissavCookies([this._entries = const {}]);

  factory _MissavCookies.fromHeader(String? header, [Object? expirations]) {
    final entries = <String, ({String value, int? expires})>{};
    for (final part in (header ?? '').split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final name = part.substring(0, separator).trim();
      final expires = expirations is Map ? expirations[name] : null;
      entries[name] = (
        value: part.substring(separator + 1).trim(),
        expires: expires is int ? expires : null,
      );
    }
    return _MissavCookies(entries);
  }

  final Map<String, ({String value, int? expires})> _entries;

  String? get header {
    final now = DateTime.now().millisecondsSinceEpoch;
    final values = [
      for (final MapEntry(key: name, value: cookie) in _entries.entries)
        if (cookie.expires == null || cookie.expires! > now)
          '$name=${cookie.value}',
    ];
    return values.isEmpty ? null : values.join('; ');
  }

  Map<String, int> get expirations => {
    for (final MapEntry(key: name, value: cookie) in _entries.entries)
      if (cookie.expires case final expires?) name: expires,
  };

  _MissavCookies withBrowserHeader(String header) {
    final incoming = _MissavCookies.fromHeader(header);
    return _MissavCookies({
      for (final MapEntry(key: name, value: cookie)
          in incoming._entries.entries)
        name: _entries[name]?.value == cookie.value ? _entries[name]! : cookie,
    });
  }

  _MissavCookies withResponse(List<String> values) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = Map.of(_entries);
    for (final value in values) {
      try {
        final cookie = Cookie.fromSetCookieValue(value);
        final maxAge = cookie.maxAge;
        final expires = maxAge == null
            ? cookie.expires?.millisecondsSinceEpoch
            : now + maxAge * Duration.millisecondsPerSecond;
        if (expires != null && expires <= now) {
          entries.remove(cookie.name);
        } else {
          entries[cookie.name] = (value: cookie.value, expires: expires);
        }
      } on FormatException {
        continue;
      }
    }
    return _MissavCookies(entries);
  }
}

class _ContentHostFailure extends MissavException {
  const _ContentHostFailure(super.message, {required super.sourceUrl});
}

class _ContentPageMissing extends MissavException {
  const _ContentPageMissing(super.message, {required super.sourceUrl});
}

typedef _AcceptedContentLine = ({String baseUrl, _ContentPage page});

class _ContentLineLoader {
  _ContentLineLoader(
    this._client,
    this._sourceUri, {
    required this.generation,
    required this.locale,
    required this.cancelToken,
    required this.details,
    required this.accountPage,
  });

  final MissavClient _client;
  final Uri _sourceUri;
  final int generation;
  final String locale;
  final CancelToken cancelToken;
  final bool details;
  final bool accountPage;
  late final _ContentPageAttempts _attempts = _ContentPageAttempts(
    cancelToken,
    MissavClient._contentPageTimeout,
    MissavClient._contentHostTimeout,
  );

  Future<_ContentPage> load() async {
    try {
      return await _load();
    } finally {
      _attempts.close();
      if (kDebugMode) {
        debugPrint('MissAV content lines attempted: ${_attempts.count}');
      }
    }
  }

  Future<_ContentPage> _load() async {
    MissavVerificationRequiredException? officialChallenge;
    StackTrace? officialChallengeTrace;
    MissavException? lastError;
    StackTrace? lastTrace;
    Future<_AcceptedContentLine?> tryLine(String baseUrl) async {
      final target = _sourceUri.replace(host: Uri.parse(baseUrl).host);
      final official = MissavClient._officialHosts.contains(target.host);
      _client._checkContentRequest(target, generation, locale, cancelToken);
      if (_attempts.expired) return null;
      try {
        final (:document, :uri) = await _attempts.load(
          target,
          (attemptToken) => _client._loadDocument(
            target,
            generation,
            cancelToken: attemptToken,
            isContentPage: true,
            allowNotFound: details,
          ),
        );
        _client._checkContentRequest(uri, generation, locale, cancelToken);
        final page = _readContentPage(document, uri);
        return (baseUrl: baseUrl, page: page);
      } on DioException catch (error) {
        if (error.type == DioExceptionType.cancel) {
          _client._checkContentRequest(target, generation, locale, cancelToken);
        }
        rethrow;
      } on MissavException catch (error, trace) {
        _client._checkContentRequest(target, generation, locale, cancelToken);
        if (accountPage) rethrow;
        final challenged =
            error is MissavVerificationRequiredException ||
            (error is MissavMirrorUnavailableException && error.challenged);
        if (official && error is MissavVerificationRequiredException) {
          officialChallenge ??= error;
          officialChallengeTrace ??= trace;
        }
        final missing = error is _ContentPageMissing;
        if (!missing && !_isContentHostFailure(error)) rethrow;
        if (_attempts.expired) return null;
        lastError = !official && error is MissavVerificationRequiredException
            ? MissavMirrorUnavailableException(
                challenged: true,
                sourceUrl: error.sourceUrl,
              )
            : error;
        lastTrace = trace;
        if (!missing) {
          _clearHostFailure(baseUrl, challenged: challenged);
        }
        return null;
      }
    }

    final hosts = _candidateHosts().toList();
    var next = 0;
    _AcceptedContentLine? accepted;
    if (details &&
        !accountPage &&
        !_client.isLoggedIn &&
        !_client._useBrowserForContent &&
        _client._preferredMirror == null &&
        hosts.length >= 2 &&
        hosts
            .take(2)
            .every(
              (base) => MissavClient._isMirrorHost(Uri.parse(base).host),
            )) {
      accepted = await _tryFirstMirrors(hosts[0], hosts[1], tryLine);
      next = 2;
    }
    while (accepted == null && next < hosts.length && !_attempts.expired) {
      accepted = await tryLine(hosts[next++]);
    }
    if (accepted != null) {
      final (:baseUrl, :page) = accepted;
      _client._checkContentRequest(page.uri, generation, locale, cancelToken);
      if (!accountPage) {
        _rememberAcceptedLine(baseUrl, page.document, page.uri);
      }
      return page;
    }
    _client._checkContentRequest(_sourceUri, generation, locale, cancelToken);
    if (officialChallenge case final error?) {
      Error.throwWithStackTrace(error, officialChallengeTrace!);
    }
    if (_attempts.expired) {
      throw _ContentHostFailure(
        'MissAV content loading timed out.',
        sourceUrl: _sourceUri.toString(),
      );
    }
    if (lastError case final error?) {
      Error.throwWithStackTrace(error, lastTrace!);
    }
    throw MissavException(
      'MissAV has no available line.',
      sourceUrl: _sourceUri.toString(),
    );
  }

  Future<_AcceptedContentLine?> _tryFirstMirrors(
    String firstHost,
    String backupHost,
    Future<_AcceptedContentLine?> Function(String) tryLine,
  ) async {
    (MissavRateLimitException, StackTrace)? primaryRateLimit;
    final primary = tryLine(firstHost).onError<MissavRateLimitException>((
      error,
      trace,
    ) {
      primaryRateLimit = (error, trace);
      return null;
    });
    final delay = Completer<bool>();
    final timer = Timer(
      MissavClient._contentBackupDelay,
      () => delay.complete(true),
    );
    final bool overlap;
    try {
      overlap = await Future.any([primary.then((_) => false), delay.future]);
    } finally {
      timer.cancel();
    }
    if (!overlap) {
      final first = await primary;
      if (first?.page.streams.isNotEmpty == true) return first;
    }

    final backup = tryLine(backupHost).onError<MissavException>((
      error,
      trace,
    ) async {
      _client._checkContentRequest(_sourceUri, generation, locale, cancelToken);
      if (await primary != null) return null;
      Error.throwWithStackTrace(error, trace);
    });
    final (fromPrimary, first) = await Future.any([
      primary.then((result) => (true, result)),
      backup.then((result) => (false, result)),
    ]);
    if (first?.page.streams.isNotEmpty == true) return first;
    final other = await (fromPrimary ? backup : primary);
    final accepted = other?.page.streams.isNotEmpty == true
        ? other
        : first ?? other;
    if (accepted == null) {
      if (primaryRateLimit case (final error, final trace)) {
        Error.throwWithStackTrace(error, trace);
      }
    }
    return accepted;
  }

  Iterable<String> _candidateHosts() {
    if (accountPage) return [_sourceUri.origin];
    if (details) {
      return {
        if (_client._automaticProbeHost case final probed?) probed,
        if (MissavClient._isMirrorHost(_sourceUri.host)) _sourceUri.origin,
        ..._contentHosts(),
        _sourceUri.origin,
        _client._activeAccountBaseUrl,
      };
    }
    return _contentHosts();
  }

  Iterable<String> _contentHosts() {
    if (_client._useBrowserForContent) return const [MissavClient.origin];
    return {
      ..._client._mirrorSelection.prioritized,
      if (_client._contentHosts.isEmpty)
        _client._remapSource(_sourceUri, baseUrl: MissavClient.origin).origin,
      for (final baseUrl in _client._contentHosts)
        if (!MissavClient._officialHosts.contains(Uri.parse(baseUrl).host))
          baseUrl,
      for (final baseUrl in missavOfficialBaseUrls)
        if (_client._contentHosts.contains(baseUrl)) baseUrl,
    };
  }

  _ContentPage _readContentPage(Document document, Uri uri) {
    final main = document.querySelector('main');
    final title = details
        ? (main?.querySelector('h1') ?? document.querySelector('h1'))?.text
              .trim()
        : null;
    final streams = details
        ? MissavClient._parseStreams(
            document,
            uri,
            userAgent: _client._userAgent,
          )
        : const <VideoStream>[];
    final hasPageContent = details
        ? streams.isNotEmpty || (main != null && (title?.isNotEmpty ?? false))
        : main != null ||
              MissavClient._parseVideos(document, uri).isNotEmpty ||
              (accountPage && MissavClient._hasAccountDirectory(document, uri));
    if (!hasPageContent) {
      throw _ContentHostFailure(
        'MissAV returned an invalid content page.',
        sourceUrl: uri.toString(),
      );
    }
    return (document: document, uri: uri, title: title, streams: streams);
  }

  void _rememberAcceptedLine(String baseUrl, Document document, Uri uri) {
    if (_client._baseUrl != baseUrl) {
      _client._baseUrl = baseUrl;
      _client._homeUrl = '$baseUrl${_client._localePrefix}';
    }
    _client._updateHomeUrl(document, uri);
    _client._mirrorSelection.remember(baseUrl);
  }

  static bool _isContentHostFailure(MissavException error) {
    if (error is _ContentHostFailure ||
        error is MissavMirrorUnavailableException ||
        error is MissavVerificationRequiredException) {
      return true;
    }
    final cause = error.cause;
    return cause is DioException && isVideoMirrorConnectionFailure(cause);
  }

  void _clearHostFailure(String baseUrl, {required bool challenged}) {
    final clearCache = _client._mirrorSelection.forget(baseUrl);
    final clearPreference = challenged && _client._preferredMirror == baseUrl;
    if (clearPreference) {
      _client._mirrorSelection.select(null);
      unawaited(_client._persistContentHost(missavMirrorBaseUrlKey, null));
    }
    if (clearCache || clearPreference) _client._notifyContentHostChanged();
  }
}

class _ContentPageAttempts {
  _ContentPageAttempts(
    CancelToken caller,
    Duration totalTimeout,
    this.hostTimeout,
  ) {
    _deadline = Timer(totalTimeout, () {
      expired = true;
      _cancelActive();
    });
    unawaited(caller.whenCancel.then((error) => _cancelActive(error.error)));
  }

  final Duration hostTimeout;
  late final Timer _deadline;
  final _active = <CancelToken>{};
  bool expired = false;
  int count = 0;

  Future<T> load<T>(Uri uri, Future<T> Function(CancelToken) request) async {
    final token = CancelToken();
    _active.add(token);
    count++;
    var timedOut = false;
    final timer = Timer(hostTimeout, () {
      timedOut = true;
      token.cancel();
    });
    try {
      return await Future.any([
        request(token),
        token.whenCancel.then<T>((error) => throw error),
      ]);
    } on DioException catch (error) {
      if (error.type != DioExceptionType.cancel || !(timedOut || expired)) {
        rethrow;
      }
      throw _ContentHostFailure(
        'MissAV content line timed out.',
        sourceUrl: uri.toString(),
      );
    } finally {
      timer.cancel();
      _active.remove(token);
    }
  }

  void _cancelActive([Object? reason]) {
    for (final token in _active) {
      token.cancel(reason);
    }
  }

  void close() {
    _deadline.cancel();
    _cancelActive();
  }
}

class _MissavSearchState {
  final Map<int, _MissavSearchPageRequest> pages = {};
  bool usesHtml = false;
}

class _MissavSearchPageRequest {
  final cancelToken = CancelToken();
  late final Future<VideoRecommendationPage?> response;
  int waiters = 0;
  bool isPending = true;
}
