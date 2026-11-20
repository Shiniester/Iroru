import 'package:dio/dio.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import 'missav_mirrors.dart';

const jableMirrorBaseUrlKey = 'jable_mirror_base_url';
const jableLastGoodHostKey = 'jable_last_good_host';
const jableMirrors = <MissavMirror>[
  MissavMirror('jable1.net'),
  MissavMirror('jable1.com'),
  MissavMirror('jable888.com'),
  MissavMirror('jable888.net'),
  MissavMirror('jable666.net'),
  MissavMirror('jable.cfd'),
  MissavMirror('91jable.top'),
];

MissavMirror? jableMirrorForBaseUrl(String? baseUrl) =>
    videoMirrorForBaseUrl(jableMirrors, baseUrl);

bool isJableMirrorCatalog(Document document) =>
    document.querySelector(
      '#site-content [id^="list_videos_"], '
      '#site-content [id^="list_models_"], '
      '#site-content [id^="list_categories_"]',
    ) !=
    null;

MissavMirrorProber createJableMirrorProber({
  Dio? dio,
  Duration timeout = const Duration(seconds: 12),
}) => MissavMirrorProber(
  dio: dio,
  timeout: timeout,
  probePath: '/new-release/',
  acceptsResponse: (mirror, response) =>
      response.realUri.origin == mirror.baseUrl &&
      isJableMirrorCatalog(html_parser.parse(response.data ?? '')),
);
