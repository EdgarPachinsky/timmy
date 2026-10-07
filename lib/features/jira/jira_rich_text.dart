import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/links.dart';
import '../../models/jira.dart';

/// A Jira description with its links underlined and clickable; they open in
/// the browser, marked with a small "external" arrow.
class JiraRichDescription extends StatefulWidget {
  const JiraRichDescription({super.key, required this.runs, this.style});

  final List<JiraTextRun> runs;
  final TextStyle? style;

  @override
  State<JiraRichDescription> createState() => _JiraRichDescriptionState();
}

class _JiraRichDescriptionState extends State<JiraRichDescription> {
  /// One tap handler per link run, by index; disposed with the widget.
  final Map<int, TapGestureRecognizer> _taps = {};

  @override
  void initState() {
    super.initState();
    _buildTaps();
  }

  @override
  void didUpdateWidget(JiraRichDescription old) {
    super.didUpdateWidget(old);
    if (!identical(old.runs, widget.runs)) _buildTaps();
  }

  void _buildTaps() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    _taps.clear();
    for (var i = 0; i < widget.runs.length; i++) {
      final url = widget.runs[i].url;
      if (url != null) _taps[i] = TapGestureRecognizer()..onTap = () => _open(url);
    }
  }

  Future<void> _open(String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!await openExternal(url)) {
      messenger?.showSnackBar(SnackBar(content: Text("Couldn't open $url")));
    }
  }

  @override
  void dispose() {
    for (final tap in _taps.values) {
      tap.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final linkStyle = base.copyWith(
      color: scheme.primary,
      decoration: TextDecoration.underline,
      decorationColor: scheme.primary.withValues(alpha: 0.5),
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (var i = 0; i < widget.runs.length; i++)
            if (_taps[i] case final tap?) ...[
              TextSpan(
                text: widget.runs[i].text,
                style: linkStyle,
                recognizer: tap,
                mouseCursor: SystemMouseCursors.click,
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2, right: 1),
                  child: Icon(Icons.open_in_new, size: 12, color: scheme.primary),
                ),
              ),
            ] else
              TextSpan(text: widget.runs[i].text),
        ],
      ),
    );
  }
}
