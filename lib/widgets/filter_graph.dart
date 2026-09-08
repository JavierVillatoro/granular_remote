import 'dart:math';
import 'package:flutter/material.dart';

// Replica del grafico interactivo de FilterModule.cpp del synth JUCE:
// misma curva de respuesta (HPF+LPF combinados) y los mismos 2 puntos
// arrastrables (HPF=izquierda, LPF=derecha) que controlan frecuencia (eje X)
// y resonancia (eje Y, arriba = mas resonancia).
//
// Todo aqui trabaja en valores normalizados 0.0-1.0 (igual que el resto del
// remoto), no en Hz/Q reales: la forma de la curva y la interaccion son
// fieles al synth, aunque el mapeo exacto Hz/Q final lo decide el propio
// parametro APVTS al recibir el OSC.
class FilterGraph extends StatefulWidget {
  final double hpf;
  final double resHpf;
  final double lpf;
  final double resLpf;
  final Color color;
  final ValueChanged<double> onHpfChanged;
  final ValueChanged<double> onResHpfChanged;
  final ValueChanged<double> onLpfChanged;
  final ValueChanged<double> onResLpfChanged;
  // Avisa mientras se arrastra un punto, para que la pantalla que lo contiene
  // (el PageView deslizante) deje de intentar cambiar de pagina a la vez.
  final ValueChanged<bool>? onDragActiveChanged;

  const FilterGraph({
    super.key,
    required this.hpf,
    required this.resHpf,
    required this.lpf,
    required this.resLpf,
    required this.color,
    required this.onHpfChanged,
    required this.onResHpfChanged,
    required this.onLpfChanged,
    required this.onResLpfChanged,
    this.onDragActiveChanged,
  });

  @override
  State<FilterGraph> createState() => _FilterGraphState();
}

class _FilterGraphState extends State<FilterGraph> {
  // -1 = ninguno, 0 = punto HPF, 1 = punto LPF (igual que draggedDot en FilterModule.cpp)
  int _draggedDot = -1;

  double _dotY(double resNorm, double height) {
    final qVal = 0.707 + (2.5 - 0.707) * resNorm;
    final qDb = 20.0 * (log(max(qVal, 0.707)) / ln10);
    final yNorm = _mapRange(qDb, -2.0, 15.0, 0.8, 0.0).clamp(0.0, 1.0);
    return yNorm * height;
  }

  static double _mapRange(
    double v,
    double inMin,
    double inMax,
    double outMin,
    double outMax,
  ) {
    return outMin + (outMax - outMin) * ((v - inMin) / (inMax - inMin));
  }

  void _onDown(Offset pos, Size size) {
    final hpfDot = Offset(
      widget.hpf * size.width,
      _dotY(widget.resHpf, size.height),
    );
    final lpfDot = Offset(
      widget.lpf * size.width,
      _dotY(widget.resLpf, size.height),
    );

    const hitRadius =
        28.0; // mas generoso que en JUCE: aqui se toca con el dedo, no con el raton
    if ((pos - hpfDot).distance < hitRadius) {
      _draggedDot = 0;
    } else if ((pos - lpfDot).distance < hitRadius) {
      _draggedDot = 1;
    } else {
      _draggedDot = -1;
      return; // no hemos tocado ningun punto: dejamos el gesto libre para el swipe
    }
    widget.onDragActiveChanged?.call(true);
  }

  void _onMove(Offset pos, Size size) {
    if (_draggedDot == -1) return;

    final px = (pos.dx / size.width).clamp(0.0, 1.0);
    final py = (pos.dy / size.height).clamp(0.0, 1.0);
    final newFreqNorm = px;
    final newResNorm = 1.0 - py;

    if (_draggedDot == 0) {
      widget.onHpfChanged(newFreqNorm);
      widget.onResHpfChanged(newResNorm);
    } else {
      widget.onLpfChanged(newFreqNorm);
      widget.onResLpfChanged(newResNorm);
    }
  }

  void _onUp() {
    if (_draggedDot == -1) return;
    _draggedDot = -1;
    widget.onDragActiveChanged?.call(false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Listener (eventos crudos de puntero) en vez de GestureDetector:
        // asi no entra en la "arena de gestos" del PageView que envuelve este
        // panel, y podemos decidir nosotros mismos, en el propio pointer-down,
        // si el toque es sobre un punto (lo capturamos) o no (dejamos que el
        // PageView reciba el swipe con normalidad).
        return Listener(
          onPointerDown: (d) => _onDown(d.localPosition, size),
          onPointerMove: (d) => setState(() => _onMove(d.localPosition, size)),
          onPointerUp: (_) => setState(_onUp),
          onPointerCancel: (_) => setState(_onUp),
          child: CustomPaint(
            size: size,
            painter: _FilterGraphPainter(
              hpf: widget.hpf,
              resHpf: widget.resHpf,
              lpf: widget.lpf,
              resLpf: widget.resLpf,
              color: widget.color,
            ),
          ),
        );
      },
    );
  }
}

class _FilterGraphPainter extends CustomPainter {
  final double hpf, resHpf, lpf, resLpf;
  final Color color;

  _FilterGraphPainter({
    required this.hpf,
    required this.resHpf,
    required this.lpf,
    required this.resLpf,
    required this.color,
  });

  static double _freqAt(double proportion) => 20.0 * pow(1000.0, proportion);

  // Q "real" (0.707-2.5), igual al rango del parametro de resonancia -> usado para la posicion del punto
  static double _rawQ(double norm) => 0.707 + (2.5 - 0.707) * norm;

  // Q "de dibujo" (0.707-8.0), igual al hQVal/lQVal de FilterModule.cpp -> usado en la formula de la curva
  static double _curveQ(double norm) => 0.707 + (8.0 - 0.707) * norm;

  double _dotY(double resNorm, double height) {
    final qDb = 20.0 * (log(max(_rawQ(resNorm), 0.707)) / ln10);
    final yNorm = _FilterGraphState._mapRange(
      qDb,
      -2.0,
      15.0,
      0.8,
      0.0,
    ).clamp(0.0, 1.0);
    return yNorm * height;
  }

  Color _brighter(Color c) {
    final hsl = HSLColor.fromColor(c);
    return hsl.withLightness((hsl.lightness + 0.2).clamp(0.0, 1.0)).toColor();
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

    final hpfFreq = _freqAt(hpf);
    final lpfFreq = _freqAt(lpf);
    final hQ = _curveQ(resHpf);
    final lQ = _curveQ(resLpf);

    final path = Path()..moveTo(0, size.height);
    const steps = 80;
    for (int i = 0; i <= steps; i++) {
      final proportion = i / steps;
      final x = size.width * proportion;
      final freq = _freqAt(proportion);

      var gTotal = 1.0;

      final hRatio = freq / hpfFreq;
      final hRatioSq = hRatio * hRatio;
      final hDenom = sqrt(pow(1.0 - hRatioSq, 2.0) + (hRatioSq / (hQ * hQ)));
      final hGain = hDenom > 1e-6 ? (hRatioSq / hDenom) : 0.0;
      gTotal *= hGain;

      final lRatio = freq / lpfFreq;
      final lRatioSq = lRatio * lRatio;
      final lDenom = sqrt(pow(1.0 - lRatioSq, 2.0) + (lRatioSq / (lQ * lQ)));
      final lGain = lDenom > 1e-6 ? (1.0 / lDenom) : 1.0;
      gTotal *= lGain;

      var totalDb = 20.0 * (log(max(gTotal, 1e-6)) / ln10);
      totalDb = totalDb.clamp(-60.0, 20.0);

      final yNorm = _FilterGraphState._mapRange(
        totalDb,
        -60.0,
        20.0,
        1.0,
        0.0,
      ).clamp(0.0, 1.0);
      path.lineTo(x, yNorm * size.height);
    }
    path.lineTo(size.width, size.height);
    path.close();

    canvas.drawPath(path, Paint()..color = color.withOpacity(0.4));
    canvas.drawPath(
      path,
      Paint()
        ..color = _brighter(color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    final hpfDot = Offset(hpf * size.width, _dotY(resHpf, size.height));
    final lpfDot = Offset(lpf * size.width, _dotY(resLpf, size.height));

    // Halo de color de capa detras de cada punto ("la misma iluminacion" que en el synth)
    final glowPaint = Paint()
      ..color = color.withOpacity(0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(hpfDot, 6, glowPaint);
    canvas.drawCircle(lpfDot, 6, glowPaint);

    final dotPaint = Paint()..color = Colors.white;
    canvas.drawCircle(hpfDot, 5, dotPaint);
    canvas.drawCircle(lpfDot, 5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _FilterGraphPainter oldDelegate) {
    return oldDelegate.hpf != hpf ||
        oldDelegate.resHpf != resHpf ||
        oldDelegate.lpf != lpf ||
        oldDelegate.resLpf != resLpf ||
        oldDelegate.color != color;
  }
}
