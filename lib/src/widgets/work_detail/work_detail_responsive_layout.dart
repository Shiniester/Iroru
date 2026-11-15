import 'package:flutter/material.dart';

typedef WorkDetailCoverBuilder =
    Widget Function(BuildContext context, bool isLandscape);

class WorkDetailResponsiveLayout extends StatefulWidget {
  const WorkDetailResponsiveLayout({
    super.key,
    required this.coverBuilder,
    required this.infoSliver,
    this.onRefresh,
  });

  final WorkDetailCoverBuilder coverBuilder;
  final Widget infoSliver;
  final RefreshCallback? onRefresh;

  @override
  State<WorkDetailResponsiveLayout> createState() =>
      _WorkDetailResponsiveLayoutState();
}

class _WorkDetailResponsiveLayoutState
    extends State<WorkDetailResponsiveLayout> {
  // Reparent the detail subtree instead of rebuilding it when orientations swap.
  final _infoSliverKey = GlobalKey(debugLabel: 'work-detail-info-sliver');

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final isLandscape =
          MediaQuery.orientationOf(context) == Orientation.landscape;
      final cover = ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              (constraints.maxHeight - MediaQuery.paddingOf(context).bottom)
                  .clamp(0.0, double.infinity)
                  .toDouble(),
        ),
        child: widget.coverBuilder(context, isLandscape),
      );
      final infoSliver = KeyedSubtree(
        key: _infoSliverKey,
        child: widget.infoSliver,
      );

      if (isLandscape) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: Center(child: cover)),
            Expanded(flex: 3, child: _buildScrollable(context, [infoSliver])),
          ],
        );
      }

      return _buildScrollable(context, [
        SliverToBoxAdapter(child: cover),
        infoSliver,
      ]);
    },
  );

  Widget _buildScrollable(BuildContext context, List<Widget> slivers) {
    final scrollable = CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        ...slivers,
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );

    if (widget.onRefresh == null) return scrollable;

    return RefreshIndicator(onRefresh: widget.onRefresh!, child: scrollable);
  }
}
