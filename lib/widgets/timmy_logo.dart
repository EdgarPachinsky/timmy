import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Timmy's palette, taken from the logo so the app and icon stay in step.
abstract final class TimmyBrand {
  static const navy = Color(0xFF222552);
  static const periwinkle = Color(0xFFBDB7F0);
  static const pink = Color(0xFFD8B2D6);
}

/// Timmy's mark, in the same family as the Gitty and Maggy icons: a pastel
/// gradient disc holding a navy monoline lowercase "t", on a near-black tile.
///
/// This painter is the single source of truth for the logo. The app uses it
/// directly, and `tool/generate_icons_test.dart` renders the macOS app icon
/// from it.
class TimmyLogoPainter extends CustomPainter {
  const TimmyLogoPainter({this.tile = true});

  /// Paint the dark rounded tile behind the disc. Without it only the disc and
  /// glyph are drawn.
  final bool tile;

  static const _navy = TimmyBrand.navy;
  static const _discTop = TimmyBrand.periwinkle;
  static const _discBottom = TimmyBrand.pink;
  static const _tileTop = Color(0xFF262628);
  static const _tileBottom = Color(0xFF0E0E0F);

  /// Disc diameter as a fraction of the tile.
  static const discFraction = 0.76;

  /// Corner radius as a fraction of the tile (matches the macOS icon grid).
  static const tileRadiusFraction = 0.225;

  /// The tile's outline, shared so callers can draw a shadow that matches.
  static RSuperellipse tileShape(double side) => RSuperellipse.fromRectAndRadius(
        Rect.fromLTWH(0, 0, side, side),
        Radius.circular(side * tileRadiusFraction),
      );

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);

    if (tile) _paintTile(canvas, side);

    // Disc.
    final diameter = side * discFraction;
    final disc = Rect.fromCenter(center: center, width: diameter, height: diameter);
    canvas.drawOval(
      disc,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment(-0.55, -1),
          end: Alignment(0.55, 1),
          colors: [_discTop, _discBottom],
        ).createShader(disc),
    );

    // Glyph, drawn in units of the disc diameter so it scales with it.
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(diameter);
    canvas.drawPath(
      _tPath(),
      Paint()
        ..color = _navy
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true,
    );
    canvas.restore();
  }

  void _paintTile(Canvas canvas, double side) {
    final shape = tileShape(side);
    final bounds = Rect.fromLTWH(0, 0, side, side);

    canvas.drawRSuperellipse(
      shape,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_tileTop, _tileBottom],
        ).createShader(bounds),
    );

    // Faint light edge along the top, like the other icons.
    final rim = side * 0.0035;
    canvas.drawRSuperellipse(
      shape.deflate(rim / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rim
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white.withValues(alpha: 0.32), Colors.white.withValues(alpha: 0)],
          stops: const [0, 0.28],
        ).createShader(bounds),
    );
  }

  // --- Glyph geometry, in units of the disc diameter, origin at its centre ---

  static const _strokeWidth = 0.062;
  static const _halfHeight = 0.20; // glyph spans +/- this, caps included
  static const _top = -_halfHeight + _strokeWidth / 2; // centre of the stroke
  static const _base = _halfHeight - _strokeWidth / 2;
  static const _hookRadius = 0.09;
  static const _tail = 0.025;
  static const _barLeft = 0.09; // crossbar reach either side of the stem
  static const _barRight = _hookRadius + _tail; // lines up with the hook's end
  static const _stemX = -(_barRight - _barLeft) / 2; // centres the glyph
  static const _barY = _top + 0.125;

  /// A geometric lowercase "t": a stem with a crossbar, curling into a short
  /// hook at the bottom. Round caps match the monoline "m" in Maggy.
  static Path _tPath() {
    final hookCentre = Offset(_stemX + _hookRadius, _base - _hookRadius);
    return Path()
      ..moveTo(_stemX, _top)
      ..lineTo(_stemX, _base - _hookRadius)
      ..arcTo(Rect.fromCircle(center: hookCentre, radius: _hookRadius), math.pi, -math.pi / 2, false)
      ..lineTo(_stemX + _hookRadius + _tail, _base)
      ..moveTo(_stemX - _barLeft, _barY)
      ..lineTo(_stemX + _barRight, _barY);
  }

  @override
  bool shouldRepaint(TimmyLogoPainter old) => old.tile != tile;
}

class TimmyLogo extends StatelessWidget {
  const TimmyLogo({super.key, this.size = 64, this.tile = true});

  final double size;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Timmy',
      image: true,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: TimmyLogoPainter(tile: tile)),
      ),
    );
  }
}
