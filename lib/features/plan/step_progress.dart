import 'package:flutter/material.dart';

/// Runs one step: shows [label] with a spinner while [work] runs, then a
/// check (or a warning when [work] returns false), then moves on.
typedef StepRunner = Future<void> Function(String label, Future<bool> Function() work);

/// A [StepRunner] that reports each change through [show] while [mounted].
/// Steps stay up long enough to read, even when the work is instant.
StepRunner stepRunner({required bool Function() mounted, required void Function(ProgressStep step) show}) =>
    (label, work) async {
      if (!mounted()) return;
      show(ProgressStep(label));
      final readable = Future<void>.delayed(const Duration(milliseconds: 600));
      final ok = await work();
      await readable;
      if (!mounted()) return;
      show(ProgressStep(label, done: true, ok: ok));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    };

/// One step of a longer job (planning, writing a standup).
class ProgressStep {
  const ProgressStep(this.label, {this.done = false, this.ok = true});

  final String label;
  final bool done;

  /// False when it finished with a problem (e.g. Trello couldn't be reached).
  final bool ok;
}

/// The current step of a job, as one line: it types in with a spinner, the
/// spinner turns into a check, then the line slides up and fades out as the
/// next one rises in. Nothing (no height) when [step] is null.
class StepProgress extends StatelessWidget {
  const StepProgress({super.key, required this.step});

  final ProgressStep? step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final step = this.step;
    final currentKey = ValueKey(step?.label ?? '');

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 340),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        // Old and new lines overlap while they swap, in one line's height.
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.centerLeft,
          children: [...previous, if (current != null) current],
        ),
        transitionBuilder: (child, animation) {
          // The new line rises from below; the old one leaves upwards.
          final incoming = child.key == currentKey;
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: Offset(0, incoming ? 0.7 : -0.7), end: Offset.zero).animate(animation),
              child: child,
            ),
          );
        },
        child: step == null
            ? const SizedBox(key: ValueKey(''), width: double.infinity)
            : Padding(
                key: currentKey,
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 260),
                        transitionBuilder: (child, animation) => ScaleTransition(
                          scale: CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                          child: FadeTransition(opacity: animation, child: child),
                        ),
                        child: !step.done
                            ? const Padding(
                                key: ValueKey('spinner'),
                                padding: EdgeInsets.all(1.5),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                step.ok ? Icons.check_circle : Icons.error_outline,
                                key: ValueKey('done-${step.ok}'),
                                size: 16,
                                color: step.ok ? const Color(0xFF22A06B) : scheme.error,
                              ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _TypedText(
                        step.done ? step.label : '${step.label}…',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: step.done ? scheme.onSurface : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// [text] written out letter by letter the first time it's shown; later
/// changes (like dropping the "…") just show.
class _TypedText extends StatefulWidget {
  const _TypedText(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_TypedText> createState() => _TypedTextState();
}

class _TypedTextState extends State<_TypedText> with SingleTickerProviderStateMixin {
  late final AnimationController _typing = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (widget.text.length * 18).clamp(150, 600)),
  )..forward();

  @override
  void dispose() {
    _typing.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _typing,
      builder: (context, _) {
        final shown = (widget.text.length * _typing.value).ceil().clamp(0, widget.text.length);
        return Text(
          widget.text.substring(0, shown),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: widget.style,
        );
      },
    );
  }
}
