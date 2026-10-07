// Renders the macOS app icon from TimmyLogoPainter.
//
//   flutter test tool/generate_icons_test.dart
//
// Writes the AppIcon set under macos/Runner/Assets.xcassets and a 1024px master
// to branding/. It is a "test" only because Flutter's headless renderer is
// available there; it is not part of the normal suite (it lives outside test/).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timmy/widgets/timmy_logo.dart';

const _sizes = [16, 32, 64, 128, 256, 512, 1024];
const _iconSet = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';

/// Apple's macOS icon grid: an 824px tile centred in a 1024px canvas, with room
/// around it for a soft drop shadow.
const _canvas = 1024.0;
const _tile = 824.0;

Future<ui.Image> _render(int pixels) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(pixels / _canvas);

  const inset = (_canvas - _tile) / 2;
  canvas.save();
  canvas.translate(inset, inset);

  // Soft shadow under the tile.
  canvas.save();
  canvas.translate(0, 12);
  canvas.drawRSuperellipse(
    TimmyLogoPainter.tileShape(_tile),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.38)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
  );
  canvas.restore();

  const TimmyLogoPainter().paint(canvas, const Size.square(_tile));
  canvas.restore();

  return recorder.endRecording().toImage(pixels, pixels);
}

void main() {
  testWidgets('generate app icons', (tester) async {
    await tester.runAsync(() async {
      for (final px in _sizes) {
        final image = await _render(px);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        await File('$_iconSet/app_icon_$px.png').writeAsBytes(bytes);
        if (px == 1024) await File('branding/timmy_icon_1024.png').writeAsBytes(bytes);
      }
    });
  });
}
