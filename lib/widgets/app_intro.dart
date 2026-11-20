import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_theme.dart';

class AppIntro extends StatefulWidget {
  const AppIntro({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<AppIntro> createState() => _AppIntroState();
}

class _AppIntroState extends State<AppIntro>
    with SingleTickerProviderStateMixin {
  static const String _word = 'VXTUBE';
  static const Color _ink = Color(0xFF08080C);

  static const double _totalMs = 2400;
  static const double _barAStart = 80, _barAEnd = 700;
  static const double _barBStart = 190, _barBEnd = 810;
  static const double _playStart = 740, _playEnd = 1080;
  static const double _lettersStart = 930, _letterStagger = 55;
  static const double _letterDuration = 400;
  static const double _ruleStart = 1280, _ruleEnd = 1780;
  static const double _exitStart = 2080;

  static const Cubic _travel = Cubic(.65, 0, .15, 1);
  static const Cubic _settle = Cubic(.34, 1.25, .5, 1);
  static const Cubic _rise = Cubic(.16, 1, .3, 1);

  late final AnimationController _c = AnimationController(vsync: this);

  bool _started = false;
  bool _reduced = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _MarkPainter.warmUp();
    _c.addStatusListener((status) {
      if (status == AnimationStatus.completed) _finish();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _reduced = MediaQuery.disableAnimationsOf(context);
    _c.duration = Duration(milliseconds: _reduced ? 1100 : _totalMs.round());
    unawaited(_c.forward());
  }

  void _finish() {
    if (_done) return;
    _done = true;
    if (mounted) widget.onFinished();
  }

  double get _ms => _c.value * _totalMs;

  double _stage(Curve curve, double from, double to) =>
      curve.transform(((_ms - from) / (to - from)).clamp(0.0, 1.0));

  double get _exitProgress {
    final start = _reduced ? .72 : _exitStart / _totalMs;
    return Curves.easeInCubic
        .transform(((_c.value - start) / (1 - start)).clamp(0.0, 1.0));
  }

  void _skip() {
    if (_done) return;
    final start = _reduced ? .72 : _exitStart / _totalMs;
    if (_c.value >= start) return;
    unawaited(_c.animateTo(
      start,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _letter(int index, double u) {
    final t = _reduced
        ? 1.0
        : _stage(
            _rise,
            _lettersStart + index * _letterStagger,
            _lettersStart + index * _letterStagger + _letterDuration,
          );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 5.5 * u),
      child: Transform.translate(
        offset: Offset(0, (1 - t) * 28 * u),
        child: Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Text(
            _word[index],
            style: TextStyle(
              color: Colors.white,
              fontSize: 23 * u,
              height: 1.1,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final markSize = (media.size.shortestSide * .30).clamp(92.0, 156.0);
    final u = markSize / 112;
    final reduced = _reduced;

    return MediaQuery(
      data: media.copyWith(textScaler: TextScaler.noScaling),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: const SystemUiOverlayStyle(
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _skip,
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final exit = _exitProgress;
              final fadeIn = reduced
                  ? Curves.easeOut.transform((_c.value / .22).clamp(0.0, 1.0))
                  : 1.0;
              final barA =
                  reduced ? 1.0 : _stage(_travel, _barAStart, _barAEnd);
              final barB =
                  reduced ? 1.0 : _stage(_travel, _barBStart, _barBEnd);
              final play =
                  reduced ? 1.0 : _stage(_settle, _playStart, _playEnd);
              final rule = reduced
                  ? 1.0
                  : _stage(Curves.easeInOutCubic, _ruleStart, _ruleEnd);

              return Opacity(
                opacity: (fadeIn * (1 - exit)).clamp(0.0, 1.0),
                child: ColoredBox(
                  color: _ink,
                  child: Center(
                    child: Transform.scale(
                      scale: 1 + .03 * exit,
                      child: SizedBox(
                        width: markSize + 140,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(
                              child: SizedBox(
                                width: markSize,
                                height: markSize,
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: _MarkPainter(
                                      a: barA,
                                      b: barB,
                                      play: play,
                                      accent: AppColors.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 34 * u),
                            ClipRect(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (var i = 0; i < _word.length; i++)
                                    _letter(i, u),
                                ],
                              ),
                            ),
                            SizedBox(height: 20 * u),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 5.5 * u,
                              ),
                              child: Align(
                                child: FractionallySizedBox(
                                  widthFactor: rule,
                                  child: Container(
                                    height: 1,
                                    color: Colors.white
                                        .withValues(alpha: .30 * rule),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.a,
    required this.b,
    required this.play,
    required this.accent,
  });

  final double a;
  final double b;
  final double play;
  final Color accent;

  static const double _lo = 8;
  static const double _hi = 92;
  static const double _w = 24;
  static const double _r = 0.7071067811865476;
  static const List<Offset> _tri = [
    Offset(43, 40),
    Offset(43, 60),
    Offset(61, 50),
  ];
  static const Offset _centroid = Offset(49, 50);

  static Path _poly(List<Offset> points) {
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  static Path _scaledTriangle(double k) => _poly([
        for (final p in _tri) _centroid + (p - _centroid) * k,
      ]);

  static final Path _barA = _poly(const [
    Offset(_lo, _lo),
    Offset(_lo + _w, _lo),
    Offset(_hi, _hi - _w),
    Offset(_hi, _hi),
    Offset(_hi - _w, _hi),
    Offset(_lo, _lo + _w),
  ]);
  static final Path _barB = _poly(const [
    Offset(_hi, _lo),
    Offset(_hi - _w, _lo),
    Offset(_lo, _hi - _w),
    Offset(_lo, _hi),
    Offset(_lo + _w, _hi),
    Offset(_hi, _lo + _w),
  ]);
  static final Path _hole = _scaledTriangle(1.42);
  static final Path _barAShape =
      Path.combine(PathOperation.difference, _barA, _hole);
  static final Path _barBShape =
      Path.combine(PathOperation.difference, _barB, _hole);
  static final Path _playShape = _scaledTriangle(1);

  static void warmUp() {
    _barAShape.getBounds();
    _barBShape.getBounds();
    _playShape.getBounds();
  }

  static Path _halfPlane(double nx, double ny, double d) {
    final p = Offset(nx * d, ny * d);
    final t = Offset(-ny, nx);
    const big = 1000.0;
    final n = Offset(nx, ny) * big;
    return _poly([p + t * big, p - t * big, p - t * big - n, p + t * big - n]);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.shortestSide / 100;
    canvas
      ..save()
      ..scale(u, u);

    final white = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;

    if (a > 0) {
      canvas.save();
      if (a < 1) {
        canvas.clipPath(_halfPlane(_r, _r, (16 + 168 * a) * _r));
      }
      canvas.drawPath(_barAShape, white);
      canvas.restore();
    }
    if (b > 0) {
      canvas.save();
      if (b < 1) {
        canvas.clipPath(_halfPlane(-_r, _r, (168 * b - 84) * _r));
      }
      canvas.drawPath(_barBShape, white);
      canvas.restore();
    }

    if (play > 0.001) {
      canvas
        ..save()
        ..translate(_centroid.dx, _centroid.dy)
        ..scale(play)
        ..translate(-_centroid.dx, -_centroid.dy);
      final fill = Paint()
        ..color = accent
        ..isAntiAlias = true;
      final edge = Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true;
      canvas
        ..drawPath(_playShape, fill)
        ..drawPath(_playShape, edge)
        ..restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) =>
      old.a != a || old.b != b || old.play != play || old.accent != accent;
}
