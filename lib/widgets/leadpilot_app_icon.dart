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
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.35),
                  blurRadius: size * 0.3,
                  spreadRadius: 2,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFF8B5CF6).withValues(alpha: 0.25),
                  blurRadius: size * 0.4,
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

    // Background squircle gradient
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          Color(0xFF0D142E),
          Color(0xFF171E42),
          Color(0xFF1E143D),
        ],
      ).createShader(rect);

    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.22));
    canvas.drawRRect(rrect, bgPaint);

    // Subtle communication radar arcs
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..color = const Color(0xFF00F5D4).withValues(alpha: 0.2);
    canvas.drawArc(
      Rect.fromCircle(center: Offset(w * 0.35, h * 0.65), radius: w * 0.32),
      -1.8,
      1.6,
      false,
      arcPaint,
    );

    // Left main wing (Cyan to Teal)
    final nose = Offset(w * 0.80, h * 0.22);
    final leftWing = Offset(w * 0.22, h * 0.48);
    final tailCenter = Offset(w * 0.44, h * 0.60);
    final rightWing = Offset(w * 0.54, h * 0.78);

    final leftWingPath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(leftWing.dx, leftWing.dy)
      ..lineTo(tailCenter.dx, tailCenter.dy)
      ..close();

    final leftPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: const [
          Color(0xFF00F5F2),
          Color(0xFF00C7A6),
          Color(0xFF1273BF),
        ],
      ).createShader(leftWingPath.getBounds());
    canvas.drawPath(leftWingPath, leftPaint);

    // Right wing (Violet to Indigo)
    final rightWingPath = Path()
      ..moveTo(nose.dx, nose.dy)
      ..lineTo(tailCenter.dx, tailCenter.dy)
      ..lineTo(rightWing.dx, rightWing.dy)
      ..close();

    final rightPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: const [
          Color(0xFFA761FF),
          Color(0xFF6B2EC9),
          Color(0xFF2E1F73),
        ],
      ).createShader(rightWingPath.getBounds());
    canvas.drawPath(rightWingPath, rightPaint);

    // Center ridge line
    final ridgePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = w * 0.018
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(nose, tailCenter, ridgePaint);

    // AI Star Sparkle at nose
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
      Paint()..color = const Color(0xFF00F2FE).withValues(alpha: 0.4),
    );
    canvas.drawPath(starPath, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

