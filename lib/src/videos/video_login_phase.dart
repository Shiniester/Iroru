import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import 'video_models.dart';

enum VideoLoginPhase {
  favoritesConfirmation,
  browserHandoff,
  sessionSave;

  String failureMessage(S strings) => switch (this) {
    favoritesConfirmation => strings.videoLoginConfirmationFailed,
    browserHandoff || sessionSave => strings.videoLoginHandoffFailed,
  };

  void logFailure(String source, Object error, int elapsedMilliseconds) {
    final category = switch (error) {
      TimeoutException() => 'timeout',
      MissavAuthenticationException() ||
      JableLoginRequiredException() => 'accountNotConfirmed',
      VideoVerificationRequired() => 'verificationRequired',
      MissavRateLimitException() => 'rateLimited',
      MissavAccessDeniedException() => 'accessDenied',
      VideoSourceException() => 'source',
      DioException(:final type) => type.name,
      PlatformException() || MissingPluginException() => 'platform',
      StateError() => 'state',
      _ => 'unexpected',
    };
    debugPrint(
      '$source login failed: stage=$name '
      'category=$category elapsedMs=$elapsedMilliseconds',
    );
  }
}
