part of '../main.dart';

class LeadPilotAppIcon extends StatelessWidget {
  const LeadPilotAppIcon({
    super.key,
    this.size = 80,
    this.showGlow = true,
  });

  final double size;
  final bool showGlow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.24),
        boxShadow: showGlow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: size * 0.25,
                  spreadRadius: 1,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFF4285F4).withValues(alpha: 0.18),
                  blurRadius: size * 0.35,
                  spreadRadius: 1,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.24),
        child: Image.asset(
          'assets/images/app_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _LeadPilotVectorPainterWidget(size: size),
        ),
      ),
    );
  }
}

class _LeadPilotVectorPainterWidget extends StatelessWidget {
  const _LeadPilotVectorPainterWidget({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(size, size),
      painter: _LeadPilotVectorPainter(),
    );
  }
}

class _LeadPilotVectorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;

    // Background clean white squircle with subtle gradient
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white,
          Color(0xFFF4F6F9),
        ],
      ).createShader(rect);

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.22));
    canvas.drawRRect(rrect, bgPaint);

    // Subtle container border
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.015
      ..color = Colors.black.withValues(alpha: 0.05);
    canvas.drawRRect(rrect, borderPaint);

    // --- Google Apps Inspired Geometric Wings ---
    final nose = Offset(w * 0.78, h * 0.28);
    final leftTip = Offset(w * 0.22, h * 0.48);
    final centerFold = Offset(w * 0.44, h * 0.62);
    final rightTip = Offset(w * 0.52, h * 0.78);
    final underBelly = Offset(w * 0.32, h * 0.70);

    // 1. Google Green: Phone / Lead Receiver body (0x34A853 -> 0x1E8E3E)
    final greenPath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(centerFold.dx, centerFold.dy)
      ..lineTo(rightTip.dx, rightTip.dy)
      ..quadraticBezierTo(w * 0.68, h * 0.68, w * 0.82, h * 0.48)
      ..close();

    final greenPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFF34A853), Color(0xFF1E8E3E)],
      ).createShader(greenPath.getBounds());
    canvas.drawPath(greenPath, greenPaint);

    // 2. Google Yellow: Speed facet / inner wing (0xFBBC05 -> 0xF9AB00)
    final yellowPath = Path()
      ..moveTo(centerFold.dx, centerFold.dy)
      ..lineTo(underBelly.dx, underBelly.dy)
      ..lineTo(rightTip.dx, rightTip.dy)
      ..close();

    final yellowPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFBBC05), Color(0xFFF9AB00)],
      ).createShader(yellowPath.getBounds());
    canvas.drawPath(yellowPath, yellowPaint);

    // 3. Google Blue: Top pilot wing (0x4285F4 -> 0x1A73E8)
    final bluePath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(leftTip.dx, leftTip.dy)
      ..lineTo(centerFold.dx, centerFold.dy)
      ..close();

    final bluePaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFF4285F4), Color(0xFF1A73E8)],
      ).createShader(bluePath.getBounds());
    canvas.drawPath(bluePath, bluePaint);

    // 4. Google Red: Trailing rudder winglet (0xEA4335 -> 0xD93025)
    final redPath = Path()
      ..moveTo(leftTip.dx, leftTip.dy)
      ..lineTo(underBelly.dx, underBelly.dy)
      ..lineTo(centerFold.dx, centerFold.dy)
      ..close();

    final redPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFEA4335), Color(0xFFD93025)],
      ).createShader(redPath.getBounds());
    canvas.drawPath(redPath, redPaint);

    // 5. White ridge line
    final ridgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = w * 0.015
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(nose, centerFold, ridgePaint);

    // 6. Google-style 4-point Sparkle Star at nose
    final starRadius = w * 0.045;
    final starPath = Path()
      ..moveTo(nose.dx, nose.dy - starRadius)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx + starRadius, nose.dy)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx, nose.dy + starRadius)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx - starRadius, nose.dy)
      ..quadraticBezierTo(nose.dx, nose.dy, nose.dx, nose.dy - starRadius)
      ..close();

    canvas.drawCircle(
      nose,
      starRadius * 1.5,
      Paint()..color = const Color(0xFF4285F4).withValues(alpha: 0.25),
    );
    canvas.drawPath(starPath, Paint()..color = Colors.white);

    // 7. Communication arc
    final wavePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.018
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF34A853).withValues(alpha: 0.35);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(w * 0.32, h * 0.70), radius: w * 0.24),
      -1.3,
      0.9,
      false,
      wavePaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

