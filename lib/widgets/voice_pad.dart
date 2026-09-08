import 'package:flutter/material.dart';

// Replica de XYPad + la barra "MIX" de FxFormantModule.cpp del synth: un
// cuadrado donde una bolita marca 2 parametros (X/Y, formante de vocal) y,
// debajo, una barra horizontal para "cuanto se quiere" (MIX), igual que el
// LinearBar mapeable que aparece bajo cada uno de los 4 "monjes" (voces) en
// el plugin. Misma reticula central, mismo halo de color de capa.
//
// La barra es gruesa y con una zona de toque bastante mas alta que su alto
// visual: con 4 de estos apretados en una rejilla 2x2, una barra fina era
// muy facil de fallar y el toque se colaba al swipe de cambiar de engine.
class VoicePad extends StatefulWidget {
  final String label;
  final double x;
  final double y;
  final double mix;
  final Color color;
  final ValueChanged<double> onXChanged;
  final ValueChanged<double> onYChanged;
  final ValueChanged<double> onMixChanged;
  // Avisa mientras se usa el gesto, para que el PageView deslizante que
  // envuelve este panel deje de intentar cambiar de pagina a la vez.
  final ValueChanged<bool>? onDragActiveChanged;

  const VoicePad({
    super.key,
    required this.label,
    required this.x,
    required this.y,
    required this.mix,
    required this.color,
    required this.onXChanged,
    required this.onYChanged,
    required this.onMixChanged,
    this.onDragActiveChanged,
  });

  @override
  State<VoicePad> createState() => _VoicePadState();
}

enum _DragTarget { none, pad, bar }

class _VoicePadState extends State<VoicePad> {
  _DragTarget _target = _DragTarget.none;
  int? _activePointer;
  // Para detectar doble-toque a mano (Listener no trae deteccion de gestos).
  DateTime? _lastPadDownTime;

  static const double _gapBeforeBar = 8;
  static const double _barHeight = 24;
  // La zona de toque de la barra es mas alta que su dibujo, para que sea
  // facil de agarrar aunque el dedo no caiga justo en el pixel visual.
  static const double _barHitPadding = 16;

  Rect _padRect(Size size) =>
      Rect.fromLTWH(0, 0, size.width, size.height - _gapBeforeBar - _barHeight);

  Rect _barRect(Size size) =>
      Rect.fromLTWH(0, size.height - _barHeight, size.width, _barHeight);

  Rect _barHitRect(Size size) => _barRect(size).inflate(_barHitPadding);

  void _updatePad(Offset pos, Rect pad) {
    final x = ((pos.dx - pad.left) / pad.width).clamp(0.0, 1.0);
    final y = (1.0 - (pos.dy - pad.top) / pad.height).clamp(0.0, 1.0);
    widget.onXChanged(x);
    widget.onYChanged(y);
  }

  void _updateBar(Offset pos, Rect bar) {
    final v = ((pos.dx - bar.left) / bar.width).clamp(0.0, 1.0);
    widget.onMixChanged(v);
  }

  void _onDown(PointerDownEvent event, Size size) {
    final pos = event.localPosition;
    // La barra se comprueba primero (y con su zona ampliada) porque su franja
    // visual es pequeña y esta pegada al borde inferior del pad.
    final barHit = _barHitRect(size);
    if (barHit.contains(pos)) {
      _target = _DragTarget.bar;
      _activePointer = event.pointer;
      _updateBar(pos, _barRect(size));
      widget.onDragActiveChanged?.call(true);
      return;
    }
    final pad = _padRect(size);
    if (pad.contains(pos)) {
      final now = DateTime.now();
      final isDoubleTap =
          _lastPadDownTime != null &&
          now.difference(_lastPadDownTime!) < const Duration(milliseconds: 300);
      _lastPadDownTime = now;
      if (isDoubleTap) {
        _lastPadDownTime = null;
        widget.onXChanged(0.5);
        widget.onYChanged(0.5);
        return;
      }

      _target = _DragTarget.pad;
      _activePointer = event.pointer;
      _updatePad(pos, pad);
      widget.onDragActiveChanged?.call(true);
    }
  }

  void _onMove(PointerMoveEvent event, Size size) {
    if (event.pointer != _activePointer) return;
    if (_target == _DragTarget.pad) {
      _updatePad(event.localPosition, _padRect(size));
    } else if (_target == _DragTarget.bar) {
      _updateBar(event.localPosition, _barRect(size));
    }
  }

  void _onUp(PointerEvent event) {
    if (event.pointer != _activePointer) return;
    _target = _DragTarget.none;
    _activePointer = null;
    widget.onDragActiveChanged?.call(false);
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
            painter: _VoicePadPainter(
              label: widget.label,
              x: widget.x,
              y: widget.y,
              mix: widget.mix,
              color: widget.color,
            ),
          ),
        );
      },
    );
  }
}

class _VoicePadPainter extends CustomPainter {
  final String label;
  final double x, y, mix;
  final Color color;

  _VoicePadPainter({
    required this.label,
    required this.x,
    required this.y,
    required this.mix,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final padRect = Rect.fromLTWH(
      0,
      0,
      size.width,
      size.height - _VoicePadState._gapBeforeBar - _VoicePadState._barHeight,
    );
    final padRRect = RRect.fromRectAndRadius(padRect, const Radius.circular(6));

    // Pantalla del pad (igual que XYPad::paint)
    canvas.drawRRect(padRRect, Paint()..color = color.withOpacity(0.15));
    canvas.drawRRect(
      padRRect,
      Paint()
        ..color = color.withOpacity(0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    final gridPaint = Paint()
      ..color = Colors.white.withOpacity(0.1)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(padRect.center.dx, padRect.top),
      Offset(padRect.center.dx, padRect.bottom),
      gridPaint,
    );
    canvas.drawLine(
      Offset(padRect.left, padRect.center.dy),
      Offset(padRect.right, padRect.center.dy),
      gridPaint,
    );

    // Etiqueta ("V1".."V4"), superpuesta en la esquina del pad (no ocupa
    // fila propia, para dejarle todo el alto posible al pad y a la barra).
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color.withOpacity(0.7),
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(padRect.left + 5, padRect.top + 3));

    // Bolita (Y invertida: 1.0 arriba, igual que en el synth)
    final dotX = padRect.left + x * padRect.width;
    final dotY = padRect.top + (1.0 - y) * padRect.height;
    canvas.drawCircle(
      Offset(dotX, dotY),
      15,
      Paint()
        ..color = color.withOpacity(0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawCircle(Offset(dotX, dotY), 8, Paint()..color = color);

    // Barra de MIX (estilo LinearBar, mas gruesa): recta (no en pildora),
    // con borde brillando sutil y relleno neon mas apagado/elegante.
    final barRect = Rect.fromLTWH(
      0,
      size.height - _VoicePadState._barHeight,
      size.width,
      _VoicePadState._barHeight,
    );
    const barRadius = Radius.circular(4);
    final barRRect = RRect.fromRectAndRadius(barRect, barRadius);
    canvas.drawRRect(barRRect, Paint()..color = Colors.black.withOpacity(0.35));

    if (mix > 0.01) {
      final fillRect = Rect.fromLTWH(
        barRect.left,
        barRect.top,
        barRect.width * mix,
        barRect.height,
      );
      // Version bien apagada del color (parecida al tono de los bordes de
      // los paneles) en vez del neon "chillon" a todo trapo.
      final hsl = HSLColor.fromColor(color);
      final softFill = hsl
          .withSaturation((hsl.saturation * 0.4).clamp(0.0, 1.0))
          .withLightness((hsl.lightness * 0.75).clamp(0.0, 1.0))
          .toColor();
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, barRadius),
        Paint()..color = softFill.withOpacity(0.55),
      );
    }

    // Borde sutil brillando alrededor de toda la barra (encima del relleno).
    canvas.drawRRect(
      barRRect,
      Paint()
        ..color = color.withOpacity(0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5),
    );
  }

  @override
  bool shouldRepaint(covariant _VoicePadPainter oldDelegate) {
    return oldDelegate.x != x ||
        oldDelegate.y != y ||
        oldDelegate.mix != mix ||
        oldDelegate.color != color ||
        oldDelegate.label != label;
  }
}
