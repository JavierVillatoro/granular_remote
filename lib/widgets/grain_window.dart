import 'dart:math';
import 'package:flutter/material.dart';

// "Ventanita de grano": Position, Grain Size y Shape del motor granular
// (EngineModule/ScanModule del synth), en un unico dibujo. La FORMA dibujada
// replica exactamente la formula que usa PluginEditor.cpp para pintar la
// ventana de grano sobre la forma de onda (mezcla Hann <-> "cuadrada" segun
// Shape), no un simple rectangulo redondeado:
//   hann   = 0.5 * (1 - cos(2*pi*progress))
//   square = rampas del 0.5% en los bordes, resto a 1.0
//   amplitud = hann*(1-shape) + square*shape
//
// Gestos (con Listener, no GestureDetector, para no perder la "arena de
// gestos" contra el PageView deslizante que envuelve este panel):
//   - 1 dedo, SOLO SI el toque empieza encima de la ventana/palito, arrastre
//     horizontal 1:1 con el dedo -> Position. Tocar en cualquier otro sitio
//     NO mueve la posicion de un salto (era molesto: un pellizco con los 2
//     dedos llegando en momentos ligeramente distintos se registraba primero
//     como "1 dedo" y saltaba la posicion antes de empezar el pellizco).
//   - 1 dedo, arrastre vertical (relativo) -> Shape, desde cualquier punto.
//   - 2 dedos, pellizco -> Grain Size (y Shape si ademas se mueve en vertical).
class GrainWindow extends StatefulWidget {
  final double position;
  final double grainSize;
  final double shape;
  final Color color;
  final ValueChanged<double> onPositionChanged;
  final ValueChanged<double> onGrainSizeChanged;
  final ValueChanged<double> onShapeChanged;
  // Avisa mientras se usa el gesto, para que el PageView deslizante que
  // envuelve este panel deje de intentar cambiar de pagina a la vez, y para
  // que el scroll vertical de toda la pantalla tampoco se dispare a la vez.
  final ValueChanged<bool>? onDragActiveChanged;

  const GrainWindow({
    super.key,
    required this.position,
    required this.grainSize,
    required this.shape,
    required this.color,
    required this.onPositionChanged,
    required this.onGrainSizeChanged,
    required this.onShapeChanged,
    this.onDragActiveChanged,
  });

  @override
  State<GrainWindow> createState() => _GrainWindowState();
}

class _GrainWindowState extends State<GrainWindow> {
  // pointerId -> ultima posicion conocida (para el delta vertical de Shape).
  final Map<int, Offset> _pointers = {};
  int? _primaryPointer; // el dedo que controla Position/Shape
  // Solo se permite arrastrar Position si el toque EMPEZO encima de la
  // ventana dibujada (si no, un toque en cualquier lado la haria saltar, y
  // un pellizco cuyos 2 dedos llegan en momentos ligeramente distintos se
  // registraba primero como "1 dedo" y daba un salto brusco no deseado).
  bool _positionArmed = false;
  double? _pinchStartDistance;
  double? _pinchStartSize;

  // Mismo margen y formula de ancho que usa el painter para la ventana: hace
  // falta para saber si un toque cae encima de ella.
  static const double _trackMargin = 12.0;

  bool _isOnWindow(Offset pos, Size size) {
    final trackWidth = size.width - _trackMargin * 2;
    final winWidth = (0.12 + widget.grainSize * 0.8) * trackWidth;
    final centerX = _trackMargin + widget.position * trackWidth;
    const extraTouchMargin = 14.0; // un poco mas generoso que el dibujo exacto
    return (pos.dx - centerX).abs() <= (winWidth / 2) + extraTouchMargin;
  }

  void _updatePositionAbsolute(double x, double width) {
    final trackWidth = width - _trackMargin * 2;
    final newPos = ((x - _trackMargin) / trackWidth).clamp(0.0, 1.0);
    widget.onPositionChanged(newPos);
  }

  void _onDown(PointerDownEvent event, Size size) {
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length == 1) {
      _primaryPointer = event.pointer;
      _positionArmed = _isOnWindow(event.localPosition, size);
    } else if (_pointers.length == 2) {
      final pts = _pointers.values.toList();
      _pinchStartDistance = (pts[0] - pts[1]).distance;
      _pinchStartSize = widget.grainSize;
      // Si llega un 2o dedo, cancelamos cualquier arrastre de posicion que
      // hubiera empezado el 1o: a partir de aqui manda el pellizco.
      _positionArmed = false;
    }
    widget.onDragActiveChanged?.call(true);
  }

  void _onMove(PointerMoveEvent event, Size size) {
    final previous = _pointers[event.pointer];
    _pointers[event.pointer] = event.localPosition;

    if (_pointers.length >= 2) {
      // Pellizco con 2 dedos: cambia el tamano. Y si ADEMAS alguno de los 2
      // dedos se mueve verticalmente, tambien cambia la forma a la vez (antes
      // se ignoraba la forma en cuanto habia 2 dedos, y no se podian combinar).
      final pts = _pointers.values.toList();
      final distance = (pts[0] - pts[1]).distance;
      final start = _pinchStartDistance;
      if (start != null && start > 1.0) {
        final newSize = (_pinchStartSize! * (distance / start)).clamp(0.0, 1.0);
        widget.onGrainSizeChanged(newSize);
      }
      if (previous != null) {
        final deltaY = event.localPosition.dy - previous.dy;
        final newShape = (widget.shape - deltaY / size.height).clamp(0.0, 1.0);
        widget.onShapeChanged(newShape);
      }
      return;
    }

    if (event.pointer == _primaryPointer && previous != null) {
      // Position: solo si el toque empezo encima de la ventana, y entonces
      // 1:1 con el dedo (no incremental).
      if (_positionArmed) {
        _updatePositionAbsolute(event.localPosition.dx, size.width);
      }
      // Shape: relativo, funciona desde cualquier punto de la caja.
      // Arriba = mas "cuadrada" (mas ataque); abajo = mas curva (Hann).
      final deltaY = event.localPosition.dy - previous.dy;
      final newShape = (widget.shape - deltaY / size.height).clamp(0.0, 1.0);
      widget.onShapeChanged(newShape);
    }
  }

  void _onUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (event.pointer == _primaryPointer) {
      _primaryPointer = _pointers.isNotEmpty ? _pointers.keys.first : null;
      _positionArmed = false;
    }
    if (_pointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartSize = null;
    }
    if (_pointers.isEmpty) widget.onDragActiveChanged?.call(false);
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
            painter: _GrainWindowPainter(
              position: widget.position,
              grainSize: widget.grainSize,
              shape: widget.shape,
              color: widget.color,
            ),
          ),
        );
      },
    );
  }
}

class _GrainWindowPainter extends CustomPainter {
  final double position, grainSize, shape;
  final Color color;

  _GrainWindowPainter({
    required this.position,
    required this.grainSize,
    required this.shape,
    required this.color,
  });

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

    // Pista horizontal (representa el sample completo). Mismo margen que usa
    // _GrainWindowState para mapear el dedo, para que el palito quede
    // exactamente alineado con la posicion real del toque.
    const margin = _GrainWindowState._trackMargin;
    final trackY = size.height / 2;
    canvas.drawLine(
      Offset(margin, trackY),
      Offset(size.width - margin, trackY),
      Paint()
        ..color = color.withOpacity(0.25)
        ..strokeWidth = 1.0,
    );

    final trackWidth = size.width - margin * 2;
    final winWidth = (0.12 + grainSize * 0.8) * trackWidth;
    final winHeight = size.height * 0.7;
    final centerX = margin + position * trackWidth;
    final left = centerX - winWidth / 2;
    final bottom = trackY + winHeight / 2;

    // Misma formula que PluginEditor.cpp: mezcla Hann <-> "cuadrada" segun Shape.
    final path = Path()..moveTo(left, bottom);
    const steps = 60;
    for (int i = 0; i <= steps; i++) {
      final progress = i / steps;
      final x = left + progress * winWidth;
      final hann = 0.5 * (1.0 - cos(2.0 * pi * progress));
      final square = progress < 0.02
          ? progress / 0.02
          : (progress > 0.98 ? (1.0 - progress) / 0.02 : 1.0);
      final amplitude = (hann * (1.0 - shape)) + (square * shape);
      final y = bottom - amplitude * winHeight;
      path.lineTo(x, y);
    }
    path.lineTo(left + winWidth, bottom);
    path.close();

    canvas.drawPath(path, Paint()..color = color.withOpacity(0.35));
    canvas.drawPath(
      path,
      Paint()
        ..color = _brighter(color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );

    // Halo de color de capa ("misma iluminacion")
    canvas.drawPath(
      path,
      Paint()
        ..color = color.withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // "Palito" de posicion: igual que PluginEditor.cpp (linea blanca vertical
    // en el centro exacto de la ventana de grano, de arriba a abajo), se
    // mueve con el dedo porque sigue directamente a Position.
    canvas.drawLine(
      Offset(centerX, 4),
      Offset(centerX, size.height - 4),
      Paint()
        ..color = Colors.white.withOpacity(0.9)
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(covariant _GrainWindowPainter oldDelegate) {
    return oldDelegate.position != position ||
        oldDelegate.grainSize != grainSize ||
        oldDelegate.shape != shape ||
        oldDelegate.color != color;
  }
}
