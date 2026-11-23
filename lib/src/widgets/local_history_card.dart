import 'package:flutter/material.dart';

import '../providers/works_provider.dart' show LayoutType;
import '../utils/collection_grid_layout.dart';

TextStyle localHistoryCardTitleStyle(BuildContext context) => TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: Theme.of(context).colorScheme.onSurface,
);

class LocalHistoryCard extends StatelessWidget {
  const LocalHistoryCard({
    super.key,
    required this.layoutType,
    required this.title,
    required this.sourceLabel,
    required this.cover,
    required this.onOpen,
    this.onResume,
    this.resumeLabel,
    this.resumeIcon = Icons.play_arrow,
    this.onRemove,
    this.progressTitle,
    this.progressText,
    this.progressTrailing,
    this.progressValue,
    this.coverOverlay,
  });

  final LayoutType layoutType;
  final String title;
  final String sourceLabel;
  final Widget cover;
  final VoidCallback onOpen;
  final VoidCallback? onResume;
  final String? resumeLabel;
  final IconData resumeIcon;
  final VoidCallback? onRemove;
  final String? progressTitle;
  final String? progressText;
  final String? progressTrailing;
  final double? progressValue;
  final Widget Function(double scale)? coverOverlay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isList = layoutType == LayoutType.list;
    final titleStyle = localHistoryCardTitleStyle(context);
    final listCoverSize = isList
        ? collectionListCoverSizeForTitle(context, titleStyle: titleStyle)
        : null;
    final padding = isList ? 12.0 : collectionGridInfoPadding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final coverWidth = listCoverSize?.width ?? constraints.maxWidth;
        final radius = collectionCoverRadius(coverWidth);
        final scale = collectionCoverInfoScale(coverWidth);
        final thumbnail = ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              cover,
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xB3000000)],
                    ),
                  ),
                  child: SizedBox(height: 60),
                ),
              ),
              if (!isList && coverOverlay != null)
                PositionedDirectional(
                  top: 8 * scale,
                  end: 8 * scale,
                  child: coverOverlay!(scale),
                ),
              if (onResume != null)
                PositionedDirectional(
                  end: 8,
                  bottom: 8,
                  child: Material(
                    color: colors.primary,
                    shape: const CircleBorder(),
                    elevation: 4,
                    child: IconButton(
                      tooltip: resumeLabel,
                      onPressed: onResume,
                      icon: Icon(resumeIcon),
                      iconSize: isList ? 20 : 24,
                      color: colors.onPrimary,
                      constraints: BoxConstraints.tightFor(
                        width: isList ? 36 : 44,
                        height: isList ? 36 : 44,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
            ],
          ),
        );
        final info = Padding(
          padding: EdgeInsets.fromLTRB(padding, padding, padding, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: collectionCardTitleMaxLines,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              if (sourceLabel.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  sourceLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );

        return Card(
          margin: isList
              ? const EdgeInsets.symmetric(
                  vertical: collectionListCardVerticalMargin,
                )
              : EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(isList ? 12 : radius),
          ),
          child: InkWell(
            onTap: onOpen,
            onLongPress: onRemove,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isList)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox.fromSize(
                          size: listCoverSize!,
                          child: thumbnail,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: info),
                      ],
                    ),
                  )
                else ...[
                  AspectRatio(
                    aspectRatio: collectionCoverAspectRatio,
                    child: thumbnail,
                  ),
                  info,
                ],
                Padding(
                  padding: EdgeInsets.fromLTRB(padding, 0, padding, padding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (progressTitle != null)
                        Text(
                          progressTitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: progressText == null
                                ? colors.onSurfaceVariant
                                : colors.secondary,
                          ),
                        ),
                      if (progressText != null || progressTrailing != null)
                        Padding(
                          padding: EdgeInsets.only(
                            top: progressTitle == null ? 0 : 4,
                          ),
                          child: Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              if (progressText != null)
                                Text(
                                  progressText!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                    color: colors.primary,
                                  ),
                                ),
                              if (progressTrailing != null)
                                Text(
                                  progressTrailing!,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (progressValue != null) ...[
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: progressValue!.clamp(0.0, 1.0),
                          backgroundColor: colors.surfaceContainerHighest,
                          color: colors.primary,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
