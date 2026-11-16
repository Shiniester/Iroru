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
import 'missav_browser_adapter.dart';
import 'missav_mirrors.dart';
import 'video_models.dart';
import 'video_source_client.dart';

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
       _contentHosts = contentHosts == null || contentHosts.isEmpty
           ? const [origin]
           : List.unmodifiable(contentHosts),
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
  static const _cookieKey = 'missav_session_cookie';
  static const _sessionRecordKey = 'missav_verified_session';
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
  HttpClientAdapter? _browserAdapter;
  Uri Function(Uri)? _mediaRoute;
  int _sessionGeneration = 0;
  CancelToken _sessionCancelToken = CancelToken();
  final List<CancelToken> _browseCancelTokens = [];
  Future<void> _pendingSessionWrite = Future.value();
  Future<void>? _initializing;
  bool _initialized = false;
  String? _cookie;
  String _userAgent = _defaultUserAgent;
  String _baseUrl = origin;
  bool _contentHostReady = false;
  String? _preferredMirror;
  String? _cachedContentHost;
  String? _accountName;
  String _locale = 'cn';
  String _homeUrl = '$origin/cn';
  bool _isLoggedIn = false;
  bool _disposed = false;
  String? _recommendationUserId;
  String? _recommendationScenario;
  final Map<String, String> _searchCursors = {};

  bool get isLoggedIn => _isLoggedIn;
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
      _browserAdapter != null ? origin : _accountBaseUrl;
  @override
  String get homeUrl => _homeUrl;

  String get originHomeUrl =>
      '$origin${_localePrefix.isEmpty ? '/' : _localePrefix}';

  @override
  String get defaultCatalogUrl => '$homeUrl/release';

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
    Uri Function(Uri)? mediaRoute,
  }) {
    if (_disposed) return;
    if (identical(adapter, _nativeAdapter)) {
      restoreNativeTransport();
      return;
    }
    if (identical(adapter, _browserAdapter)) return;

    final previousBrowserAdapter = _browserAdapter;
    _advanceSessionGeneration();
    _baseUrl = origin;
    _homeUrl = '$origin${_localePrefix.isEmpty ? '/' : _localePrefix}';
    _contentHostReady = true;
    _browserAdapter = adapter;
    _mediaRoute = mediaRoute;
    _dio.httpClientAdapter = adapter;
    if (previousBrowserAdapter != null &&
        !identical(previousBrowserAdapter, _nativeAdapter)) {
      previousBrowserAdapter.close(force: true);
    }
    notifyListeners();
  }

  void restoreNativeTransport() {
    if (_disposed) return;
    _advanceSessionGeneration();
    final browserAdapter = _browserAdapter;
    _browserAdapter = null;
    _contentHostReady = false;
    _mediaRoute = null;
    _dio.httpClientAdapter = _nativeAdapter;
    if (browserAdapter != null && !identical(browserAdapter, _nativeAdapter)) {
      browserAdapter.close(force: true);
    }
    notifyListeners();
  }

  void selectMirror(String? baseUrl) {
    if (_disposed) return;
    final mirror = missavMirrorForBaseUrl(baseUrl);
    if (_browserAdapter != null) {
      restoreNativeTransport();
    } else {
      _advanceSessionGeneration();
    }
    _preferredMirror = mirror?.baseUrl;
    _contentHostReady = true;
    if (mirror != null) {
      _baseUrl = mirror.baseUrl;
      _homeUrl = '${mirror.baseUrl}$_localePrefix';
    } else {
      _baseUrl = _cachedContentHost ?? _contentHosts.first;
      _homeUrl = '$_baseUrl$_localePrefix';
    }
    notifyListeners();
  }

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
    if (_browserAdapter != null) return;
    if (_contentHostReady) return;
    _baseUrl = _preferredMirror ?? _cachedContentHost ?? _contentHosts.first;
    _homeUrl = '$_baseUrl$_localePrefix';
    _contentHostReady = true;
  }

  Iterable<({String baseUrl, bool official})> _contentHostCandidates() sync* {
    if (_browserAdapter != null) {
      yield (baseUrl: origin, official: true);
      return;
    }
    final candidates = <({String baseUrl, bool official})>[];
    final seen = <String>{};
    void add(String? baseUrl, {required bool official}) {
      if (baseUrl == null || !seen.add(baseUrl)) return;
      candidates.add((baseUrl: baseUrl, official: official));
    }

    add(_preferredMirror, official: false);
    add(_cachedContentHost, official: false);
    for (final baseUrl in _contentHosts) {
      add(baseUrl, official: _officialHosts.contains(Uri.parse(baseUrl).host));
    }
    yield* candidates;
  }

  Future<void> _persistLastGoodHost(String? baseUrl) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(missavLastGoodHostKey, baseUrl ?? '');
    } catch (_) {
      // A preference write failure must not fail the page load.
    }
  }

  Future<void> _persistPreferredMirror(String? baseUrl) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(missavMirrorBaseUrlKey, baseUrl ?? '');
    } catch (_) {
      // Keep the in-memory fallback when preferences are unavailable.
    }
  }

  Future<void> _clearContentHostFailure(
    String baseUrl, {
    required bool challenged,
  }) async {
    var changed = false;
    if (_cachedContentHost == baseUrl) {
      _cachedContentHost = null;
      await _persistLastGoodHost(null);
      changed = true;
    }
    if (challenged && _preferredMirror == baseUrl) {
      _preferredMirror = null;
      await _persistPreferredMirror(null);
      changed = true;
    }
    if (changed && !_disposed) notifyListeners();
  }

  static bool _stopContentFallback(MissavException error, CancelToken token) {
    if (token.isCancelled) return true;
    if (error.message.contains('account changed') ||
        error.message.contains('language changed')) {
      return true;
    }
    final cause = error.cause;
    return cause is DioException && cause.type == DioExceptionType.cancel;
  }

  Future<void> _loadSession() async {
    final generation = _sessionGeneration;
    try {
      try {
        final preferences = await SharedPreferences.getInstance();
        final savedMirror = preferences.getString(missavMirrorBaseUrlKey);
        final mirror = missavMirrorForBaseUrl(savedMirror);
        final cachedRaw = preferences.getString(missavLastGoodHostKey);
        final cachedHost = missavMirrorForBaseUrl(cachedRaw);
        if (generation == _sessionGeneration && !_disposed) {
          _preferredMirror ??= mirror?.baseUrl;
          _cachedContentHost ??= cachedHost?.baseUrl;
          final accountHost = preferences.getString(missavAccountBaseUrlKey);
          if (accountHosts.contains(accountHost)) {
            _accountBaseUrl = accountHost!;
          }
          if (!_contentHostReady) {
            final base = _preferredMirror ?? _cachedContentHost;
            if (base != null) {
              _baseUrl = base;
              _homeUrl = '$base$_localePrefix';
            }
          }
        }
        if (savedMirror != null && savedMirror.isNotEmpty && mirror == null) {
          await preferences.setString(missavMirrorBaseUrlKey, '');
        }
        if (cachedRaw != null && cachedRaw.isNotEmpty && cachedHost == null) {
          await preferences.setString(missavLastGoodHostKey, '');
        }
      } catch (_) {
        // A missing preference store leaves automatic mirror selection on.
      }
      final record = await _secureStorage.read(key: _sessionRecordKey);
      final legacyCookie = await _secureStorage.read(key: _cookieKey);
      final session = _decodeStoredSession(record);
      if (generation == _sessionGeneration && !_disposed) {
        _cookie = session?.cookie ?? legacyCookie;
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
    MissavVerificationRequiredException? officialChallenge;
    StackTrace? officialChallengeTrace;
    Object? lastError;
    StackTrace? lastTrace;
    try {
      _contentHostReady = true;
      for (final candidate in _contentHostCandidates()) {
        if (requestCancelToken.cancelError case final error?) throw error;
        _baseUrl = candidate.baseUrl;
        _homeUrl = '${candidate.baseUrl}$_localePrefix';
        try {
          final page = await _browse(
            url,
            cancelToken: requestCancelToken,
            onParsed: onParsed,
          );
          if (!candidate.official) {
            _cachedContentHost = candidate.baseUrl;
            await _persistLastGoodHost(candidate.baseUrl);
          }
          return page;
        } on MissavVerificationRequiredException catch (error, trace) {
          lastError = error;
          lastTrace = trace;
          if (candidate.official) {
            officialChallenge ??= error;
            officialChallengeTrace ??= trace;
          }
          await _clearContentHostFailure(candidate.baseUrl, challenged: true);
        } on MissavMirrorUnavailableException catch (error, trace) {
          lastError = error;
          lastTrace = trace;
          await _clearContentHostFailure(
            candidate.baseUrl,
            challenged: error.challenged,
          );
        } on MissavException catch (error, trace) {
          if (_stopContentFallback(error, requestCancelToken)) rethrow;
          lastError = error;
          lastTrace = trace;
          await _clearContentHostFailure(candidate.baseUrl, challenged: false);
        } on DioException catch (error, trace) {
          if (error.type == DioExceptionType.cancel) rethrow;
          lastError = error;
          lastTrace = trace;
          await _clearContentHostFailure(candidate.baseUrl, challenged: false);
        }
      }
      if (officialChallenge != null) {
        Error.throwWithStackTrace(
          officialChallenge,
          officialChallengeTrace ?? StackTrace.current,
        );
      }
      if (lastError != null) {
        Error.throwWithStackTrace(lastError, lastTrace ?? StackTrace.current);
      }
      throw MissavException('MissAV has no available line.', sourceUrl: url);
    } finally {
      _browseCancelTokens.remove(requestCancelToken);
    }
  }

  Future<String?> loadPlaylistCover(
    String url, {
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.cancelError case final error?) throw error;
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final playlistUri = _localizedSourceUri(url).removeFragment();
    final queryParameters = <String, dynamic>{
      for (final entry in playlistUri.queryParametersAll.entries)
        if (entry.key != 'page')
          entry.key: entry.value.length == 1 ? entry.value.single : entry.value,
    };
    final uri = queryParameters.isEmpty
        ? Uri.parse(playlistUri.toString().split('?').first)
        : playlistUri.replace(queryParameters: queryParameters);
    final requestCancelToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(requestCancelToken);
    try {
      if (requestCancelToken.cancelError case final error?) throw error;
      final document = await _loadDocument(
        uri,
        generation,
        cancelToken: requestCancelToken,
      );
      if (requestCancelToken.cancelError case final error?) throw error;
      _checkGeneration(generation, uri);
      if (_locale != locale) {
        throw MissavException(
          'MissAV language changed during the request.',
          sourceUrl: uri.toString(),
        );
      }
      final videos = _parseVideos(document, uri);
      final cover = videos.isEmpty ? null : videos.first.cover;
      return cover == null || cover.isEmpty ? null : cover;
    } finally {
      _browseCancelTokens.remove(requestCancelToken);
    }
  }

  Future<void> checkBrowserAccess({Map<String, dynamic>? browserUser}) async {
    await initialize();
    final browser = _browserAdapter;
    if (browser == null ||
        (browser is MissavBrowserAdapter && browser.isClosed)) {
      await _prepareOnlineAccess();
    }
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = _localizedSourceUri(homeUrl);
    final document = await _loadDocument(uri, generation);
    _checkGeneration(generation, uri);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    final sourceUser = _readAccountFromPage(document) ?? browserUser;
    if (sourceUser is Map) _updateAccountFromSource(sourceUser);
    _updateHomeUrl(document, uri);
  }

  Future<VideoCatalogPage> _browse(
    String url, {
    required CancelToken cancelToken,
    void Function(VideoCatalogPage page)? onParsed,
  }) async {
    final generation = _sessionGeneration;
    final uri = _localizedSourceUri(url);
    final locale = _locale;
    final document = await _loadDocument(
      uri,
      generation,
      cancelToken: cancelToken,
    );
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    _updateAccountFromPage(document);
    _updateHomeUrl(document, uri);
    final parsedVideos = _parseVideos(document, uri);
    var videos = parsedVideos;
    var nextUrl = _paginationUrl(document, uri, 'next');
    var previousUrl = _paginationUrl(document, uri, 'prev');
    var currentPage = _pageNumber(uri) ?? 1;
    var jumpMaxPage = _jumpMaxPage(document, uri);
    final searchQuery = _searchQuery(uri);
    if (searchQuery != null) {
      final apiPage = await _searchRecommendations(
        searchQuery,
        currentPage,
        cancelToken: cancelToken,
      );
      if (apiPage.videos.isNotEmpty) {
        videos = apiPage.videos;
        nextUrl = apiPage.cursor == null
            ? null
            : uri
                  .replace(
                    queryParameters: {
                      ...uri.queryParameters,
                      'page': '${currentPage + 1}',
                    },
                  )
                  .toString();
        previousUrl = currentPage > 1
            ? uri
                  .replace(
                    queryParameters: {
                      ...uri.queryParameters,
                      'page': '${currentPage - 1}',
                    },
                  )
                  .toString()
            : null;
        jumpMaxPage = null;
      }
    }
    final parsedPage = VideoCatalogPage(
      title: _pageTitle(document),
      url: uri.toString(),
      videos: videos,
      links: _parseLinks(document, uri),
      navigation: _parseNavigation(document, uri),
      nextUrl: nextUrl,
      previousUrl: previousUrl,
      currentPage: currentPage,
      jumpMaxPage: jumpMaxPage,
    );
    if (cancelToken.cancelError case final error?) throw error;
    onParsed?.call(parsedPage);
    final enriched = await _enrichVideos(videos, cancelToken: cancelToken);
    _checkGeneration(generation, uri);
    if (cancelToken.cancelError case final error?) throw error;
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }

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
    final uri = _localizedSourceUri(homeUrl);
    final requestCancelToken = cancelToken ?? CancelToken();
    _browseCancelTokens.add(requestCancelToken);
    try {
      if (requestCancelToken.cancelError case final error?) throw error;
      if (cursor == null) {
        _recommendationUserId = null;
        _recommendationScenario = null;
        final document = await _loadDocument(
          uri,
          generation,
          cancelToken: requestCancelToken,
        );
        _updateAccountFromPage(document);
        _updateHomeUrl(document, uri);
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

  Future<VideoRecommendationPage> _searchRecommendations(
    String query,
    int page, {
    CancelToken? cancelToken,
  }) async {
    final key = '$_locale:$query';
    final cursor = _searchCursors[key];
    if (page > 1 && cursor == null) {
      return const VideoRecommendationPage(videos: [], cursor: null);
    }
    final Map<String, Object?> data;
    final String path;
    if (page <= 1 || cursor == null) {
      _searchCursors.remove(key);
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
    final Object? response;
    try {
      response = await _requestRecommendations(
        path,
        data,
        cancelToken: cancelToken ?? _sessionCancelToken,
      );
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) rethrow;
      return const VideoRecommendationPage(videos: [], cursor: null);
    }
    if (response is! Map ||
        response['recomms'] is! List ||
        response['recommId'] is! String) {
      return const VideoRecommendationPage(videos: [], cursor: null);
    }
    final recommId = response['recommId'] as String;
    final videos = <VideoItem>[];
    for (final entry in response['recomms'] as List) {
      if (entry is! Map || entry['id'] is! String || entry['values'] is! Map) {
        continue;
      }
      videos.add(
        _recommendationVideo(
          entry['id'] as String,
          entry['values'] as Map,
          _locale,
        ),
      );
    }
    if (videos.isEmpty) {
      return const VideoRecommendationPage(videos: [], cursor: null);
    }
    _searchCursors[key] = recommId;
    return VideoRecommendationPage(videos: videos, cursor: recommId);
  }

  VideoItem _recommendationVideo(
    String id,
    Map values,
    String titleLocale, {
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
          '$_baseUrl$prefix$_localePrefix/${Uri.encodeComponent(id)}',
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
    );
  }

  Future<List<VideoItem>> loadRelatedRecommendations(VideoItem video) async {
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
      });
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
          videos.add(_recommendationVideo(id, values, titleLocale));
        }
      }
      final enriched = await _enrichVideos(videos);
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
    List<VideoItem> videos, {
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
        return _withVideoMetadata(video, values, localePrefix);
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
              url: '$_baseUrl$prefix/$route/${Uri.encodeComponent(name)}',
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
  }) async {
    await _prepareOnlineAccess();
    final generation = _sessionGeneration;
    final locale = _locale;
    final uri = _localizedSourceUri(item.pageUrl);
    final document = await _loadDocument(uri, generation);
    if (_locale != locale) {
      throw MissavException(
        'MissAV language changed during the request.',
        sourceUrl: uri.toString(),
      );
    }
    _updateAccountFromPage(document);
    final title =
        (document.querySelector('main h1') ?? document.querySelector('h1'))
            ?.text
            .trim();
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
    final saved = _savedState(document);
    final related = _parseVideos(
      document,
      uri,
    ).where((related) => related.id != item.id).toList();
    final initialDetails = VideoDetails(
      video: video,
      description: _parseDescription(document),
      metadata: metadata,
      related: related,
      streams: _parseStreams(document, uri, userAgent: _userAgent).map((
        stream,
      ) {
        final route = _mediaRoute;
        if (route == null) return stream;
        return VideoStream(
          label: stream.label,
          url: route(Uri.parse(stream.url)).toString(),
          isHls: stream.isHls,
        );
      }).toList(),
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
    );
  }

  Future<VideoDetails> supplementDetails(
    VideoDetails details, {
    FutureOr<void> Function(VideoDetails)? onReady,
  }) async {
    await _prepareOnlineAccess();
    return _supplementDetails(
      details,
      generation: _sessionGeneration,
      locale: _locale,
      saved: details.isFavorite,
      onReady: onReady,
    );
  }

  Future<VideoDetails> _supplementDetails(
    VideoDetails initialDetails, {
    required int generation,
    required String locale,
    bool? saved,
    FutureOr<void> Function(VideoDetails)? onReady,
    bool includeAccountState = true,
  }) async {
    final uri = _sourceUri(initialDetails.video.pageUrl);
    _checkGeneration(generation, uri);
    final enrichment = _enrichVideos([
      initialDetails.video,
      ...initialDetails.related,
    ]);
    final sourceId = initialDetails.sourceId;
    Object? accountError;
    StackTrace? accountTrace;
    final accountBase = _activeAccountBaseUrl;
    if (sourceId != null &&
        includeAccountState &&
        (_browserAdapter != null ||
            _officialHosts.contains(Uri.parse(_baseUrl).host))) {
      final viewUri = Uri.parse(
        '$accountBase/api/items/${Uri.encodeComponent(sourceId)}/view',
      );
      try {
        final viewResponse = await _request(viewUri, generation: generation);
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
    }
    final enriched = await enrichment;
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
      final selectedAccountHost = _accountBaseUrl;
      _accountBaseUrl = origin;
      await _loginAt(origin, email: email, password: password);
      await selectAccountHost(selectedAccountHost);
      return;
    }
    final previous = _accountBaseUrl;
    final hosts = [previous, ...accountHosts.where((host) => host != previous)];
    MissavException? lastError;
    for (final host in hosts) {
      _accountBaseUrl = host;
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
    _accountBaseUrl = previous;
    throw lastError ?? const MissavException('MissAV login failed.');
  }

  static bool _canRetryLogin(MissavException error) {
    if (error is MissavAuthenticationException) return false;
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
    final uri = Uri.parse('$base/en/api/login');
    final pageUri = Uri.parse('$base/en');

    Future<Response<dynamic>> sendLogin() => _request(
      uri,
      method: 'POST',
      data: {'email': email, 'password': password, 'remember': true},
      generation: generation,
    );

    try {
      if (_cookieValue('XSRF-TOKEN') == null) {
        await _request(pageUri, generation: generation, direct: true);
      }
      late Response<dynamic> response;
      try {
        response = await sendLogin();
      } on MissavException catch (error) {
        if (!error.message.contains('HTTP 419')) rethrow;
        await _request(pageUri, generation: generation, direct: true);
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
      if (user == null) {
        final document = _parsePage(text, uri);
        final sourceUser = _readAccountFromPage(document);
        if (sourceUser is Map) {
          user = Map<String, dynamic>.from(sourceUser);
        }
      }
      if (user == null) {
        final homeUri = Uri.parse('$base/en');
        final homeResponse = await _request(
          homeUri,
          generation: generation,
          direct: true,
        );
        final homeText = homeResponse.data is String
            ? homeResponse.data as String
            : '';
        final document = _parsePage(homeText, homeUri);
        final sourceUser = _readAccountFromPage(document);
        if (sourceUser is Map) {
          user = Map<String, dynamic>.from(sourceUser);
        }
      }
      if (user == null) {
        throw MissavException(
          'MissAV returned an invalid login response.',
          sourceUrl: uri.toString(),
        );
      }
      var canCloseBrowser = _browserAdapter != null;
      if (_browserAdapter case final MissavBrowserAdapter browser) {
        final readCookies = browser.readCookieHeader;
        if (readCookies == null) {
          canCloseBrowser = false;
        } else {
          try {
            final browserCookie = await readCookies();
            if (browserCookie.isEmpty) {
              canCloseBrowser = false;
            } else {
              await importVerifiedSession(
                cookieHeader: browserCookie,
                userAgent: _userAgent,
                expectedGeneration: generation,
              );
            }
          } catch (_) {
            canCloseBrowser = false;
          }
        }
      }
      _accountName = _accountNameFrom(user) ?? email;
      _setAccountState(loggedIn: true, notify: false);
      if (_browserAdapter != null && canCloseBrowser) {
        // The hidden browser only verifies the source session.
        selectMirror(_preferredMirror);
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
    final accountChanged = _isLoggedIn || _accountName != null;
    _cookie = cookieHeader;
    _userAgent = userAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();

    await _writeSession(generation, () async {
      await _persistSession(
        generation,
        cookie: cookieHeader,
        userAgent: userAgent,
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
    final document = await _loadDocument(actorUri, generation);
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

  Future<Document> _loadDocument(
    Uri uri,
    int generation, {
    CancelToken? cancelToken,
  }) async {
    _checkGeneration(generation, uri);
    final adapter = _browserAdapter;
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
      body =
          (await _request(
                uri,
                generation: generation,
                cancelToken: cancelToken,
              )).data
              as String;
    }
    _checkGeneration(generation, uri);
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
        throw MissavException(
          'MissAV returned HTTP $status.',
          sourceUrl: uri.toString(),
        );
      }
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
    return document;
  }

  Future<Response<dynamic>> _request(
    Uri uri, {
    String method = 'GET',
    Object? data,
    int? generation,
    CancelToken? cancelToken,
    bool direct = false,
  }) async {
    if (generation == null) await _prepareOnlineAccess();
    final requestGeneration = generation ?? _sessionGeneration;
    final requestCancelToken = cancelToken ?? _sessionCancelToken;
    final isApi = uri.pathSegments.contains('api');
    var requestUri = isApi || direct
        ? _sourceUri(uri.toString())
        : _remapSource(_sourceUri(uri.toString()));
    var requestMethod = method;
    var requestData = data;

    for (var redirect = 0; redirect <= _pageLimit; redirect++) {
      _checkGeneration(requestGeneration, requestUri);
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
        final cookie = _cookie;
        // The account session is shared by MissAV's official hosts only.
        final forwardsSession = _officialHosts.contains(requestUri.host);
        if (forwardsSession && cookie != null && cookie.isNotEmpty) {
          headers['Cookie'] = cookie;
          final xsrfToken = _cookieValue('XSRF-TOKEN');
          if (xsrfToken != null) {
            headers['X-XSRF-TOKEN'] = Uri.decodeComponent(xsrfToken);
          }
        }
      }

      late final Response<dynamic> response;
      try {
        response = await _dio.request<dynamic>(
          requestUri.toString(),
          data: requestData,
          cancelToken: requestCancelToken,
          options: Options(
            method: requestMethod,
            headers: headers,
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) =>
                status != null && status >= 200 && status < 500,
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

      final status = response.statusCode ?? 0;
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (status == HttpStatus.forbidden ||
          _isChallengeResponse(response.data) ||
          response.headers.value('cf-mitigated')?.trim().toLowerCase() ==
              'challenge') {
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
      await _saveResponseCookies(response, requestUri, requestGeneration);
      _checkGeneration(requestGeneration, requestUri);
      if (status >= 300 && status < 400 && location != null) {
        final redirectedUri = requestUri.resolve(location);
        if (!_isSource(redirectedUri)) {
          throw MissavUnsupportedException(
            capability: 'following a redirect outside MissAV',
            sourceUrl: redirectedUri.toString(),
          );
        }
        requestUri = redirectedUri;
        if (status == 303 ||
            ((status == 301 || status == 302) && requestMethod != 'GET')) {
          requestMethod = 'GET';
          requestData = null;
        }
        continue;
      }
      if (status == HttpStatus.unauthorized) {
        if (!uri.path.endsWith('/api/login')) {
          _updateAccountFromSource(null);
        }
        throw MissavAuthenticationException(sourceUrl: requestUri.toString());
      }
      if (status < 200 || status >= 300) {
        throw MissavException(
          'MissAV returned HTTP $status.',
          sourceUrl: requestUri.toString(),
        );
      }
      return response;
    }

    throw MissavException(
      'MissAV redirected too many times.',
      sourceUrl: uri.toString(),
    );
  }

  Future<void> _saveResponseCookies(
    Response<dynamic> response,
    Uri uri,
    int generation,
  ) async {
    if (!_officialHosts.contains(uri.host) ||
        generation != _sessionGeneration) {
      return;
    }
    final values = response.headers['set-cookie'];
    if (values == null || values.isEmpty) return;

    await _writeSession(generation, () async {
      final cookies = <String, String>{};
      for (final part in (_cookie ?? '').split(';')) {
        final separator = part.indexOf('=');
        if (separator > 0) {
          cookies[part.substring(0, separator).trim()] = part
              .substring(separator + 1)
              .trim();
        }
      }
      for (final value in values) {
        try {
          final cookie = Cookie.fromSetCookieValue(value);
          if ((cookie.maxAge != null && cookie.maxAge! <= 0) ||
              (cookie.expires != null &&
                  cookie.expires!.isBefore(DateTime.now()))) {
            cookies.remove(cookie.name);
          } else {
            cookies[cookie.name] = cookie.value;
          }
        } on FormatException {
          continue;
        }
      }

      final updatedCookie = cookies.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('; ');
      await _persistSession(
        generation,
        cookie: updatedCookie.isEmpty ? null : updatedCookie,
        userAgent: _userAgent,
      );
      if (generation == _sessionGeneration) {
        _cookie = updatedCookie.isEmpty ? null : updatedCookie;
        if (updatedCookie.isEmpty) _userAgent = _defaultUserAgent;
      }
    });
  }

  Future<void> _persistSession(
    int generation, {
    required String? cookie,
    required String userAgent,
  }) async {
    if (cookie == null) {
      await _secureStorage.delete(key: _sessionRecordKey);
      if (generation == _sessionGeneration) {
        await _secureStorage.delete(key: _cookieKey);
      }
      return;
    }

    await _secureStorage.write(
      key: _sessionRecordKey,
      value: jsonEncode({'cookie': cookie, 'userAgent': userAgent}),
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
    _cookie = null;
    _userAgent = _defaultUserAgent;
    _accountName = null;
    _setAccountState(loggedIn: false, notify: false);
    if (accountChanged && !_disposed) notifyListeners();
    await _writeSession(generation, () async {
      await _secureStorage.delete(key: _sessionRecordKey);
      await _secureStorage.delete(key: _cookieKey);
    });
  }

  static ({String cookie, String userAgent})? _decodeStoredSession(
    String? value,
  ) {
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
        return (cookie: cookie, userAgent: userAgent);
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

  String? _cookieValue(String name) {
    for (final pair in (_cookie ?? '').split(';')) {
      final separator = pair.indexOf('=');
      if (separator > 0 && pair.substring(0, separator).trim() == name) {
        return pair.substring(separator + 1).trim();
      }
    }
    return null;
  }

  void _setAccountState({required bool loggedIn, bool notify = true}) {
    if (_isLoggedIn == loggedIn) return;
    _isLoggedIn = loggedIn;
    if (notify && !_disposed) notifyListeners();
  }

  int _advanceSessionGeneration() {
    _recommendationUserId = null;
    _recommendationScenario = null;
    _searchCursors.clear();
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

  Uri _remapSource(Uri uri) {
    if (!_isSource(uri)) return uri;
    final base = Uri.parse(_baseUrl);
    if (uri.host == base.host) return uri;
    if (_baseUrl == origin &&
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

  Uri _localizedSourceUri(String url) {
    final uri = _remapSource(_sourceUri(url));
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
    if (_isChallengeResponse(source)) {
      throw MissavVerificationRequiredException(sourceUrl: uri.toString());
    }
    return html_parser.parse(source);
  }

  static bool _isChallengeResponse(Object? body) {
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
      _accountName = null;
      _setAccountState(loggedIn: false, notify: false);
    } else {
      return;
    }
    if (previousName != _accountName || previousLoginState != _isLoggedIn) {
      if (!_disposed) notifyListeners();
    }
  }

  void _updateAccountFromPage(Document document) {
    final sourceUser = _readAccountFromPage(document);
    // Public user:null markup needs runtime state or /view to confirm sign-in.
    if (sourceUser is Map) {
      _updateAccountFromSource(sourceUser);
    }
  }

  static Object? _readAccountFromPage(Document document) {
    final runtimeUser = document.querySelector('#kiko-missav-runtime-user');
    if (runtimeUser != null) {
      try {
        final user = jsonDecode(runtimeUser.text);
        if (user is Map) return user;
      } on FormatException {
        // Fall back to page markup if the runtime snapshot is invalid.
      }
    }
    for (final element in document.querySelectorAll('[x-data]')) {
      final source = element.attributes['x-data'] ?? '';
      final match = RegExp(r'\buser\s*:\s*(null|\{)').firstMatch(source);
      if (match == null) continue;
      if (match.group(1) == 'null') return null;
      final user = <String, dynamic>{};
      final property = RegExp(
        r'''['"]?(email|username|name)['"]?\s*:\s*(['"])(.*?)\2''',
      ).firstMatch(source.substring(match.end));
      if (property != null) user[property.group(1)!] = property.group(3);
      return user;
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
      if (!_isSource(itemUri)) continue;
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
    final videoAnchors = document
        .querySelectorAll('div.relative.aspect-w-16.aspect-h-9 a[href]')
        .toSet();
    final videoUrls = videoAnchors
        .map(
          (anchor) => pageUri
              .resolve(anchor.attributes['href']!)
              .removeFragment()
              .toString(),
        )
        .toSet();
    final navigationAnchors = document.querySelectorAll('nav a[href]').toSet();
    final links = <VideoLink>[];
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (videoAnchors.contains(anchor) ||
          navigationAnchors.contains(anchor) ||
          _isLanguageAnchor(anchor)) {
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
          kind: _browseLinkKind(uri),
        ),
      );
    }
    return links;
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
    final nativeAdapter = _nativeAdapter;
    final activeAdapter = _dio.httpClientAdapter;
    _browserAdapter = null;
    _mediaRoute = null;
    _dio.close(force: true);
    _metadataDio.close(force: true);
    if (!identical(activeAdapter, nativeAdapter)) {
      nativeAdapter.close(force: true);
    }
    super.dispose();
  }
}
