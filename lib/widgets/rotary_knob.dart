import 'dart:math';
import 'package:flutter/material.dart';

// Knob rotativo estilo hardware: se gira arrastrando el dedo verticalmente,
// igual que los knobs de FilterModule/LayerMixerModule en el synth JUCE.
class RotaryKnob extends StatelessWidget {
  final double value; // 0.0 - 1.0
  final ValueChanged<double> onChanged;
  final Color color;
  final String label;
  final double size;

  const RotaryKnob({
    super.key,
    required this.value,
    required this.onChanged,
    required this.color,
    required this.label,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onVerticalDragUpdate: (details) {
            // Arrastrar hacia arriba sube el valor, hacia abajo lo baja.
            final next = (value - details.delta.dy / 150.0).clamp(0.0, 1.0);
            onChanged(next);
          },
          child: SizedBox(
            width: size,
            height: size,
            child: CustomPaint(
              painter: _RotaryKnobPainter(value: value, color: color),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Alto fijo (no el natural del texto) para que otros widgets puedan
        // alinearse con precision respecto al inicio de esta etiqueta.
        SizedBox(
          height: 14,
          child: Text(
            label,
            style: TextStyle(
              letterSpacing: 1.2,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color.withOpacity(0.8),
            ),
          ),
        ),
      ],
    );
  }
}

class _RotaryKnobPainter extends CustomPainter {
  final double value;
  final Color color;

  _RotaryKnobPainter({required this.value, required this.color});

  static const double _startAngle = 0.75 * pi; // 135 grados
  static const double _sweepAngle = 1.5 * pi; // 270 grados

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle, false, trackPaint);

    final activePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _startAngle, _sweepAngle * value, false, activePaint);

    // Cuerpo del knob
    final bodyPaint = Paint()..color = const Color(0xFF1A1A1D);
    canvas.drawCircle(center, radius - 8, bodyPaint);

    // Indicador de posicion
    final pointerAngle = _startAngle + _sweepAngle * value;
    final pointerStart =
        center + Offset(cos(pointerAngle), sin(pointerAngle)) * (radius - 16);
    final pointerEnd =
        center + Offset(cos(pointerAngle), sin(pointerAngle)) * (radius - 8);
    final pointerPaint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pointerStart, pointerEnd, pointerPaint);
  }

  @override
  bool shouldRepaint(covariant _RotaryKnobPainter oldDelegate) {
    return oldDelegate.value != value || oldDelegate.color != color;
  }
}
