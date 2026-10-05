// f0-flutter : bench CustomPainter sur corpus fidèle, mesure paint() par frame
// + export JSON dans un <div id="result">. Cible web (CanvasKit/SkWasm = Skia).
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

void main() {
  final q = html.window.location.search ?? '';
  final scene = int.tryParse(
          q.split('scene=').last.split('&').first.replaceAll('?', '')) ??
      1;
  runApp(BenchApp(scene: scene));
}

class BenchApp extends StatefulWidget {
  final int scene;
  const BenchApp({super.key, required this.scene});
  @override
  State<BenchApp> createState() => _BenchAppState();
}

class _BenchAppState extends State<BenchApp>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final List<double> times = [];
  int frames = 0;
  late CorpusPainter painter;

  @override
  void initState() {
    super.initState();
    painter = CorpusPainter(widget.scene);
    _ticker = createTicker((_) {
      setState(() {
        frames++;
        if (frames == 120) {
          _ticker.stop();
          final avg = times.reduce((a, b) => a + b) / times.length;
          final json =
              '{"tool":"flutter-3.35.4","renderer":"canvaskit|skwasm","scene":"s${widget.scene}","paint_ms_avg":${avg.toStringAsFixed(3)},"paint_ms_first":${times.first.toStringAsFixed(3)},"paint_ms_n":${times.length},"frames":$frames}';
          html.document.getElementById('result')?.text = json;
        }
      });
    })..start();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox.expand(
          // nouveau delegate à chaque build => repaint garanti à chaque frame
          child: CustomPaint(
              painter: CorpusPainter(widget.scene)..times = times,
              size: const Size(800, 600)),
        ),
      ),
    );
  }
}

class CorpusPainter extends CustomPainter {
  final int scene;
  List<double> times = [];
  CorpusPainter(this.scene);

  @override
  void paint(Canvas canvas, Size size) {
    final sw = Stopwatch()..start();
    final w = size.width, h = size.height;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    switch (scene) {
      case 1: // 200 formes translucides
        for (var i = 0; i < 200; i++) {
          final p = Paint()
            ..color = Color.fromRGBO(
                (i * 37) % 255, (i * 91) % 255, (i * 57) % 255, 0.55);
          final x = (i * 13) % (w - 60), y = (i * 29) % (h - 40);
          if (i % 3 == 0) {
            canvas.drawRect(Rect.fromLTWH(x, y, 60, 40), p);
          } else if (i % 3 == 1) {
            canvas.drawCircle(Offset(x + 25.0, y + 25.0), 25, p);
          } else {
            canvas.drawRRect(
                RRect.fromLTRBR(x, y, x + 70, y + 30, const Radius.circular(8)),
                p);
          }
        }
        break;
      case 2: // texte
        for (var i = 0; i < 20; i++) {
          final tp = TextPainter(
            text: TextSpan(
                text: 'Titre — évaluation Klaxon f0 bench §éçà€ 0123456789',
                style: TextStyle(
                    fontSize: i % 5 == 0 ? 20 : 14,
                    color: const Color(0xFF1A1A33))),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 560);
          tp.paint(canvas, Offset(40, (40 + i * 22).toDouble()));
        }
        break;
      case 3: // blur : 8 ellipses avec MaskFilter Blur
        for (var i = 0; i < 8; i++) {
          final p = Paint()
            ..color = Color.fromRGBO(
                (30 * i) % 255, 80 + i * 15, 220, 0.85)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
          canvas.drawOval(
              Rect.fromLTWH(
                  40 + i * 90.0, 120 + i * 45.0, 140, 140),
              p);
        }
        break;
      case 4: // images (générées procéduralement via PictureRecorder)
        final rec = ui.PictureRecorder();
        final rc = Canvas(rec);
        rc.drawRect(
            Rect.fromLTWH(0, 0, 256, 256), Paint()..color = Colors.blue[400]!);
        rc.drawRect(
            Rect.fromLTWH(20, 20, 100, 100), Paint()..color = Colors.red);
        rc.drawOval(
            Rect.fromLTWH(120, 120, 100, 100), Paint()..color = Colors.white);
        final img = rec.endRecording().toImageSync(256, 256);
        for (var i = 0; i < 50; i++) {
          canvas.drawImageRect(
              img,
              Rect.fromLTWH(0, 0, 256, 256),
              Rect.fromLTWH((i * 67) % (w - 120), (i * 43) % (h - 120), 120, 120),
              Paint());
        }
        break;
      case 6: // 100 paths bézier
        final p = Paint()
          ..color = const Color.fromRGBO(20, 40, 160, 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        for (var i = 0; i < 100; i++) {
          final path = Path()
            ..moveTo(((i * 7) % w).toDouble(), h - 60)
            ..cubicTo((60 + i * 5).toDouble(), (80 + i * 2).toDouble(),
                (320 - i).toDouble(), (40 + i * 4).toDouble(), 700.0,
                ((300 + i * 6) % (h - 20)).toDouble());
          canvas.drawPath(path, p);
        }
        break;
      case 8: // composite : clip + transform + layers
        for (var i = 0; i < 10; i++) {
          canvas.save();
          canvas.clipRect(Rect.fromLTWH(
              60 + i * 40, 60 + i * 30, 400 - i * 20, 260 - i * 12));
          canvas.translate(20 + i * 10, 10 + i * 8);
          canvas.rotate((3 + i) * pi / 180);
          canvas.drawRect(
              Rect.fromLTWH(0, 0, 500, 320),
              Paint()
                ..color = Color.fromRGBO(
                    40 + i * 20, 180 - i * 10, 120, 0.43));
          canvas.restore();
        }
        for (var i = 0; i < 20; i++) {
          canvas.drawOval(
              Rect.fromLTWH(i * 30.0, i * 22.0, 80, 80),
              Paint()..color = Color.fromRGBO(230, 128, 51, 0.6));
        }
        break;
    }
    times.add(sw.elapsedMicroseconds / 1000.0);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => true;
}
