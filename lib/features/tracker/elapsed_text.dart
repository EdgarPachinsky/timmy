import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../state/tracker_controller.dart';

/// Live `HH:MM:SS` readout of [TrackerController.elapsed].
///
/// The controller computes elapsed time from timestamps; this widget only
/// schedules repaints, and only while the timer is running.
class ElapsedText extends StatefulWidget {
  const ElapsedText({super.key, required this.controller, this.style});

  final TrackerController controller;
  final TextStyle? style;

  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(ElapsedText old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncTicker();
    }
  }

  void _onControllerChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    if (widget.controller.isRunning) {
      _ticker ??= Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    return Text(
      formatClock(widget.controller.elapsed),
      style: base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}
