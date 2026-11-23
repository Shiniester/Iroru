import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../widgets/global_audio_player_wrapper.dart';

class VideoSourceAccountPage extends StatelessWidget {
  const VideoSourceAccountPage({
    super.key,
    required this.title,
    required this.status,
    required this.signedIn,
    required this.busy,
    required this.onAccountAction,
    this.error,
    this.recoveryActions = const [],
  });

  final String title;
  final String? status;
  final bool signedIn;
  final bool busy;
  final VoidCallback? onAccountAction;
  final String? error;
  final List<Widget> recoveryActions;

  @override
  Widget build(BuildContext context) {
    final strings = S.of(context);
    return GlobalAudioPlayerWrapper(
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                Icon(
                  Icons.account_circle_outlined,
                  size: 56,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                if (status case final message?) ...[
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                ],
                if (onAccountAction case final action?)
                  FilledButton.icon(
                    onPressed: busy ? null : action,
                    icon: Icon(signedIn ? Icons.logout : Icons.login),
                    label: Text(signedIn ? strings.logout : strings.login),
                  ),
                if (busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
                if (error case final message?) ...[
                  const SizedBox(height: 12),
                  Text(message, textAlign: TextAlign.center),
                ],
                ...recoveryActions,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
