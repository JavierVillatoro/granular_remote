import 'package:flutter/material.dart';

// Curva retro de ecualizador de 4 bandas (Low, Mid-L, Mid-H, High), a juego
// con el dibujo del filtro: misma linea brillante + relleno + halo de color de
// capa, con 4 puntitos blancos arrastrables verticalmente (arriba = mas
// ganancia, abajo = menos), uno por banda. No replica ningun widget existente
// del synth (LayerMixerModule no dibuja curva), es la version visual nueva
// del propio mixer de 4 bandas.
class EqCurve extends StatefulWidget {
  final double low;
  final double midLow;
  final double midHigh;
  final double high;
  final Color color;
  final ValueChanged<double> onLowChanged;
  final ValueChanged<double> onMidLowChanged;
  final ValueChanged<double> onMidHighChanged;
  final ValueChanged<double> onHighChanged;
  // Avisa mientras se arrastra un punto, para que el PageView deslizante que
  // envuelve este panel deje de intentar cambiar de pagina a la vez.
  final ValueChanged<bool>? onDragActiveChanged;

  const EqCurve({
    super.key,
    required this.low,
    required this.midLow,
    required this.midHigh,
    required this.high,
    required this.color,
    required this.onLowChanged,
    required this.onMidLowChanged,
    required this.onMidHighChanged,
    required this.onHighChanged,
    this.onDragActiveChanged,
  });

  @override
  State<EqCurve> createState() => _EqCurveState();
}

class _EqCurveState extends State<EqCurve> {
  // pointerId -> que banda arrastra (0..3). Un Map en vez de un solo int
  // permite mover 2 bandas a la vez con 2 dedos.
  final Map<int, int> _pointerToBand = {};
  // Para detectar doble-toque a mano (Listener no trae deteccion de gestos),
  // guardado por banda (no por dedo).
  final Map<int, DateTime> _lastDownTimeByBand = {};

  static const List<double> _xFractions = [0.125, 0.375, 0.625, 0.875];

  List<double> get _values => [
    widget.low,
    widget.midLow,
    widget.midHigh,
    widget.high,
  ];

  List<Offset> _dotPositions(Size size) {
    final values = _values;
    return List.generate(4, (i) {
      final x = _xFractions[i] * size.width;
      final y = (1.0 - values[i]) * size.height;
      return Offset(x, y);
    });
  }

  void _resetBand(int i) {
    switch (i) {
      case 0:
        widget.onLowChanged(0.5);
        break;
      case 1:
        widget.onMidLowChanged(0.5);
        break;
      case 2:
        widget.onMidHighChanged(0.5);
        break;
      case 3:
        widget.onHighChanged(0.5);
        break;
    }
  }

  void _onDown(PointerDownEvent event, Size size) {
    final pos = event.localPosition;
    final dots = _dotPositions(size);
    const hitRadius = 28.0;
    for (int i = 0; i < dots.length; i++) {
      if ((pos - dots[i]).distance >= hitRadius) continue;
      if (_pointerToBand.containsValue(i)) continue; // ya la arrastra otro dedo

      final now = DateTime.now();
      final lastDown = _lastDownTimeByBand[i];
      final isDoubleTap =
          lastDown != null &&
          now.difference(lastDown) < const Duration(milliseconds: 300);
      _lastDownTimeByBand[i] = now;
      if (isDoubleTap) {
        _lastDownTimeByBand.remove(i);
        _resetBand(i);
        return;
      }

      _pointerToBand[event.pointer] = i;
      widget.onDragActiveChanged?.call(true);
      return;
    }
  }

  void _onMove(PointerMoveEvent event, Size size) {
    final band = _pointerToBand[event.pointer];
    if (band == null) return;
    final newVal = 1.0 - (event.localPosition.dy / size.height).clamp(0.0, 1.0);
    switch (band) {
      case 0:
        widget.onLowChanged(newVal);
        break;
      case 1:
        widget.onMidLowChanged(newVal);
        break;
      case 2:
        widget.onMidHighChanged(newVal);
        break;
      case 3:
        widget.onHighChanged(newVal);
        break;
    }
  }

  void _onUp(PointerEvent event) {
    if (_pointerToBand.remove(event.pointer) == null) return;
    if (_pointerToBand.isEmpty) widget.onDragActiveChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerDown: (d) => _onDown(d, size),
          onPointerMove: (d) => setState(() => _onMove(d, size)),
          onPointerUp: (d) => setState(() => _onUp(d)),
          onPointerCancel: (d) => setState(() => _onUp(d)),
          child: CustomPaint(
            size: size,
            painter: _EqCurvePainter(values: _values, color: widget.color),
          ),
        );
      },
    );
  }
}

class _EqCurvePainter extends CustomPainter {
  final List<double> values; // [low, midLow, midHigh, high], 0-1 (0.5 = plano)
  final Color color;

  _EqCurvePainter({required this.values, required this.color});

  static const List<double> _xFractions = [0.125, 0.375, 0.625, 0.875];

  Color _brighter(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + 0.2).clamp(0.0, 1.0)).toColor();
  }

  // Catmull-Rom -> Bezier: anade la curva suave que pasa por los 4 puntos
  // directamente al "path" recibido (que ya debe estar posicionado en
  // pts.first), en vez de crear un Path nuevo con su propio moveTo.
  // path.addPath() crea un contorno/PathMetric SEPARADO (no conectado), lo
  // que dejaba un hueco de muestreo justo en la costura al rellenar la curva
  // (el "platito" sin rellenar junto al primer punto blanco).
  void _addSmoothCubics(Path path, List<Offset> pts) {
    final before = pts[0] * 2 - pts[1];
    final after = pts[3] * 2 - pts[2];
    final ext = [before, ...pts, after];

    for (int i = 1; i < ext.length - 2; i++) {
      final p0 = ext[i - 1];
      final p1 = ext[i];
      final p2 = ext[i + 1];
      final p3 = ext[i + 2];
      final cp1 = p1 + (p2 - p0) / 6.0;
      final cp2 = p2 - (p3 - p1) / 6.0;
      path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
    canvas.drawRRect(rrect, Paint()..color = color.withOpacity(0.05));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final centerY = size.height / 2;
    // Linea de referencia "plano" (equivalente a la linea de 0dB del fader)
    canvas.drawLine(
      Offset(4, centerY),
      Offset(size.width - 4, centerY),
      Paint()
        ..color = color.withOpacity(0.35)
        ..strokeWidth = 1.0,
    );

    final dots = List.generate(4, (i) {
      final x = _xFractions[i] * size.width;
      final y = (1.0 - values[i]) * size.height;
      return Offset(x, y);
    });

    // La curva ocupa todo el ancho: tramo recto hasta la 1a banda, curva
    // suave entre las 4 bandas, tramo recto desde la ultima banda. Todo en
    // un unico contorno continuo (sin addPath) para que el muestreo de mas
    // abajo no tenga costuras.
    final curve = Path()
      ..moveTo(0, dots.first.dy)
      ..lineTo(dots.first.dx, dots.first.dy);
    _addSmoothCubics(curve, dots);
    curve.lineTo(size.width, dots.last.dy);

    // Relleno entre la curva y la linea central (retro EQ look).
    // OJO: como la curva puede cruzar la linea central varias veces (subir y
    // bajar), un unico Path cerrado "curva + vuelta recta por el centro" da
    // un relleno erroneo (aparecia un triangulo sin rellenar en los graves).
    // En vez de eso, muestreamos la curva ya trazada y pintamos un trapecio
    // por cada tramo pequeno entre la curva y el centro: cada trapecio cae
    // siempre en el lado correcto (arriba o abajo), sin importar cuantas
    // veces cruce la curva la linea central.
    final fillPaint = Paint()..color = color.withOpacity(0.3);
    Offset? previous;
    for (final metric in curve.computeMetrics()) {
      const step = 4.0;
      double d = 0;
      while (d < metric.length) {
        final tangent = metric.getTangentForOffset(d);
        if (tangent != null) {
          final point = tangent.position;
          if (previous != null) {
            final quad = Path()
              ..moveTo(previous.dx, previous.dy)
              ..lineTo(point.dx, point.dy)
              ..lineTo(point.dx, centerY)
              ..lineTo(previous.dx, centerY)
              ..close();
            canvas.drawPath(quad, fillPaint);
          }
          previous = point;
        }
        d += step;
      }
      // Tramo final hasta el propio extremo del contorno (si "length" no es
      // multiplo exacto de "step", sin esto se pierde el ultimo trocito).
      final endTangent = metric.getTangentForOffset(metric.length);
      if (endTangent != null && previous != null) {
        final point = endTangent.position;
        final quad = Path()
          ..moveTo(previous.dx, previous.dy)
          ..lineTo(point.dx, point.dy)
          ..lineTo(point.dx, centerY)
          ..lineTo(previous.dx, centerY)
          ..close();
        canvas.drawPath(quad, fillPaint);
      }
    }
    canvas.drawPath(
      curve,
      Paint()
        ..color = _brighter(color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    final glowPaint = Paint()
      ..color = color.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final dotPaint = Paint()..color = Colors.white;
    for (final dot in dots) {
      canvas.drawCircle(dot, 6, glowPaint);
      canvas.drawCircle(dot, 5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _EqCurvePainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.values[0] != values[0] ||
        oldDelegate.values[1] != values[1] ||
        oldDelegate.values[2] != values[2] ||
        oldDelegate.values[3] != values[3];
  }
}
