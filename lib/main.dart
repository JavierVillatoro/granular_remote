import 'package:flutter/material.dart';
import 'dart:async';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:osc/osc.dart';
import 'dart:io';
import 'widgets/rotary_knob.dart';
import 'widgets/filter_graph.dart';
import 'widgets/eq_curve.dart';
import 'widgets/grain_window.dart';

void main() => runApp(const GranularRemoteApp());

class GranularRemoteApp extends StatelessWidget {
  const GranularRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner:
          false, // Quitamos la etiqueta molesta de Debug
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(
          0xff0A0A0C,
        ), // Negro más profundo y elegante
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xff0A0A0C),
          elevation: 0,
        ),
      ),
      home: const RemoteScreen(),
    );
  }
}

class RemoteScreen extends StatefulWidget {
  const RemoteScreen({super.key});

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final AudioRecorder audioRecorder = AudioRecorder();
  final TextEditingController ipController = TextEditingController(
    text: "192.168.1.100",
  );
  final PageController enginePageController = PageController();

  static const List<String> _layers = ["L1", "L2", "L3", "L4"];

  String selectedLayer = "L1";
  bool isRecording = false;
  int currentEnginePage = 0;
  // Mientras se arrastra un puntito del filtro o de la curva de EQ, bloqueamos
  // el swipe del PageView para que no compitan por el mismo gesto.
  bool lockPageSwipe = false;
  void setDragLock(bool active) => setState(() => lockPageSwipe = active);
  // Boton de candado: congela todos los controles de la pantalla de engines
  // (sliders, knobs, puntitos) para poder deslizar entre Mixer/Filtro sin
  // riesgo de tocar un parametro por error. El swipe entre paginas sigue
  // funcionando siempre, solo se bloquean los controles de dentro.
  bool engineLocked = false;
  // Menu de modulos: alternativa a arrastrar, para saltar directo a un engine.
  bool showModuleMenu = false;

  // --- ESTADO POR CAPA ---
  // Cada L1-L4 recuerda su propio valor: al cambiar de capa, los controles
  // deben volver a la posicion que se dejo en esa capa, no quedarse en la ultima tocada.
  final Map<String, bool> playStates = {for (var l in _layers) l: false};
  final Map<String, double> filterValues = {for (var l in _layers) l: 1.0};
  final Map<String, double> hpfValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> resLpfValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> resHpfValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> eqLowValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> eqMidLowValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> eqMidHighValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> eqHighValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> volValues = {for (var l in _layers) l: 0.75};

  // --- ESTADO DEL ENGINE GRANULAR (tercer engine) ---
  // 3 de los 12 se controlan solo desde GrainWindow (ventana de grano):
  final Map<String, double> positionValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> grainSizeValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> shapeValues = {for (var l in _layers) l: 0.0};
  // Los otros 9 son la rejilla de knobs 3x3:
  final Map<String, double> densityValues = {for (var l in _layers) l: 0.4};
  final Map<String, double> scanSpeedValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> scanModeValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> sprayPosValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> sprayPitchValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> sprayPanValues = {for (var l in _layers) l: 0.0};
  final Map<String, double> pitchTransValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> pitchFineValues = {for (var l in _layers) l: 0.5};
  final Map<String, double> pitchScaleValues = {for (var l in _layers) l: 0.0};

  // Tabla de despacho: sufijo de la direccion OSC -> mapa de estado al que
  // pertenece. Se usa tanto para el receptor en vivo (Feature de sync) como
  // referencia de que direcciones existen; PLAY se trata aparte por ser bool.
  late final Map<String, Map<String, double>> _oscDispatch = {
    'FILTER_LPF': filterValues,
    'FILTER_HPF': hpfValues,
    'FILTER_RES_LPF': resLpfValues,
    'FILTER_RES_HPF': resHpfValues,
    'EQ_LOW': eqLowValues,
    'EQ_MID_LOW': eqMidLowValues,
    'EQ_MID_HIGH': eqMidHighValues,
    'EQ_HIGH': eqHighValues,
    'MIX_VOL': volValues,
    'POSITION': positionValues,
    'GRAIN_SIZE': grainSizeValues,
    'SHAPE': shapeValues,
    'DENSITY': densityValues,
    'SCAN_SPEED': scanSpeedValues,
    'SCAN_MODE': scanModeValues,
    'SPRAY_POS': sprayPosValues,
    'SPRAY_PITCH': sprayPitchValues,
    'SPRAY_PAN': sprayPanValues,
    'PITCH_TRANS': pitchTransValues,
    'PITCH_FINE': pitchFineValues,
    'PITCH_SCALE': pitchScaleValues,
  };

  RawDatagramSocket? _receiveSocket;
  static const int _receivePort = 9001;
  static final RegExp _layerAddressPattern = RegExp(r'^/?(L[1-4])_(.+)$');

  @override
  void initState() {
    super.initState();
    _startOscReceiver();
  }

  @override
  void dispose() {
    _receiveSocket?.close();
    super.dispose();
  }

  // --- RECEPTOR OSC: sincronizacion en vivo desde el plugin ---
  // Escucha en un puerto fijo (9001, distinto del 9000 de envio) los cambios
  // de parametro que el plugin emite (p.ej. al cargar un preset) y actualiza
  // el estado local. Nunca reenvia OSC al recibir, para no crear un bucle.
  Future<void> _startOscReceiver() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _receivePort,
      );
      _receiveSocket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        try {
          final message = OSCMessage.fromBytes(datagram.data);
          _handleIncomingOsc(message);
        } catch (e) {
          print("Error OSC entrante: $e");
        }
      });
    } catch (e) {
      print("No se pudo abrir el puerto de sincronizacion $_receivePort: $e");
    }
  }

  void _handleIncomingOsc(OSCMessage message) {
    if (message.arguments.isEmpty) return;
    final rawValue = message.arguments.first;
    final value = rawValue is double
        ? rawValue
        : (rawValue is int ? rawValue.toDouble() : null);
    if (value == null) return;

    final match = _layerAddressPattern.firstMatch(message.address);
    if (match == null) return;
    final layer = match.group(1)!;
    final suffix = match.group(2)!;

    if (suffix == 'PLAY') {
      setState(() => playStates[layer] = value > 0.5);
      return;
    }
    final store = _oscDispatch[suffix];
    if (store == null) return;
    setState(() => store[layer] = value.clamp(0.0, 1.0));
  }

  bool get isPlaying => playStates[selectedLayer]!;
  double get filterValue => filterValues[selectedLayer]!;

  // --- LÓGICA DE COLOR DINÁMICO ---
  // Esta función devuelve el color exacto dependiendo de la capa activa
  Color get activeColor {
    switch (selectedLayer) {
      case "L1":
        return Colors.cyanAccent;
      case "L2":
        return Colors.pinkAccent;
      case "L3":
        return Colors.orangeAccent;
      case "L4":
        return Colors.lightGreenAccent;
      default:
        return Colors.cyanAccent;
    }
  }

  // --- NÚCLEO OSC ---
  void sendOscMessage(String address, double value) {
    try {
      final dest = InternetAddress(ipController.text);
      const port = 9000;
      final message = OSCMessage(address, arguments: [value]);

      RawDatagramSocket.bind(InternetAddress.anyIPv4, 0).then((socket) {
        socket.send(message.toBytes(), dest, port);
        socket.close();
      });
    } catch (e) {
      print("Error OSC: $e");
    }
  }

  // --- NÚCLEO HTTP ---
  Future<void> sendAudioToPlugin(String filePath) async {
    final url = Uri.parse('http://${ipController.text}:8080');
    try {
      final fileBytes = await File(filePath).readAsBytes();
      final response = await http.post(
        url,
        headers: {'Content-Type': 'audio/wav', 'layer': selectedLayer},
        body: fileBytes,
      );
      if (response.statusCode == 200)
        print("Audio enviado con éxito a la capa $selectedLayer");
    } catch (e) {
      print("Error HTTP: $e");
    } finally {
      // EL DIRECTOR DE ORQUESTA: El móvil apaga el REC del PC aquí, de forma segura
      sendOscMessage('/${selectedLayer}_REC', 0.0);
    }
  }

  // --- LÓGICA DE GRABACIÓN ---
  void toggleRecording() async {
    if (!isRecording) {
      if (await audioRecorder.hasPermission()) {
        final directory = await getApplicationDocumentsPath();
        final path = '$directory/temp_audio.wav';
        await audioRecorder.start(
          const RecordConfig(encoder: AudioEncoder.wav),
          path: path,
        );
        setState(() => isRecording = true);

        sendOscMessage('/${selectedLayer}_R_MODE', 1.0);
        sendOscMessage('/${selectedLayer}_REC', 1.0);
      }
    } else {
      final path = await audioRecorder.stop();
      setState(() => isRecording = false);
      //sendOscMessage('/${selectedLayer}_REC', 0.0);
      if (path != null) sendAudioToPlugin(path);
    }
  }

  void togglePlay() {
    setState(() => playStates[selectedLayer] = !isPlaying);
    sendOscMessage('/${selectedLayer}_PLAY', isPlaying ? 1.0 : 0.0);
  }

  // --- WIDGET: PAD DE COLOR ---
  Widget buildColorPad(String layerName, Color baseColor) {
    bool isSelected = selectedLayer == layerName;
    return GestureDetector(
      onTap: () {
        // Al tocar, abrimos llaves para hacer múltiples acciones:
        setState(
          () => selectedLayer = layerName,
        ); // 1. Cambia visualmente en el móvil

        // 2. Extraemos el número (ej: de "L2" sacamos un 2.0) y lo enviamos al PC
        double layerNum = double.parse(layerName.substring(1));
        sendOscMessage('/SELECT_LAYER', layerNum);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutExpo,
        width: isSelected ? 70 : 60,
        height: isSelected ? 70 : 60,
        decoration: BoxDecoration(
          color: isSelected
              ? baseColor.withOpacity(0.15)
              : const Color(0xFF1A1A1D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? baseColor : Colors.white10,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: baseColor.withOpacity(0.4),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ]
              : [],
        ),
        child: Center(
          child: Text(
            layerName,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: isSelected ? 20 : 16,
              color: isSelected ? baseColor : Colors.white54,
            ),
          ),
        ),
      ),
    );
  }

  // --- WIDGET: BOTON DE PLAY (color de la capa activa, sin texto) ---
  Widget buildPlayButton() {
    return GestureDetector(
      onTap: togglePlay,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 86,
        height: 86,
        decoration: BoxDecoration(
          color: isPlaying ? activeColor : const Color(0xFF1A1A1D),
          shape: BoxShape.circle,
          // Sin "glow" de color: si el REC esta grabando a la vez (rojo, con su
          // propio halo grande), un segundo halo de color junto a el se mezclaria
          // y contrastaria mal. El relleno solido ya deja claro que esta activo.
          border: Border.all(
            color: isPlaying ? activeColor : Colors.white12,
            width: isPlaying ? 3 : 3,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 10,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Icon(
          isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
          color: isPlaying ? Colors.black : activeColor,
          size: 34,
        ),
      ),
    );
  }

  // --- WIDGET: MINI SLIDER ETIQUETADO (usado en el panel de filtro) ---
  // Doble toque sobre el slider para volver a "resetValue" de un golpe.
  Widget buildMiniSlider(
    BuildContext context,
    String label,
    double value,
    ValueChanged<double> onChanged, {
    required double resetValue,
  }) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              letterSpacing: 1.2,
              color: activeColor.withOpacity(0.8),
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onDoubleTap: () => onChanged(resetValue),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: activeColor,
                inactiveTrackColor: Colors.white10,
                trackHeight: 5.0,
                thumbColor: activeColor,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 9.0,
                ),
                overlayColor: activeColor.withOpacity(0.2),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 18.0,
                ),
              ),
              child: Slider(
                value: value,
                min: 0.0,
                max: 1.0,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- WIDGET: PANEL "FILTRO" (LPF, HPF, sus resonancias, y el dibujo de la curva) ---
  Widget buildFilterPanel(BuildContext context) {
    void sendFilter(String suffix, Map<String, double> store, double val) {
      setState(() => store[selectedLayer] = val);
      sendOscMessage('/${selectedLayer}_$suffix', val);
    }

    // Mismo orden visual que FilterModule::resized() en el synth: columna
    // izquierda = HPF (corte arriba, resonancia abajo), columna derecha = LPF.
    return Column(
      children: [
        Row(
          children: [
            buildMiniSlider(
              context,
              "HIGH PASS",
              hpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_HPF", hpfValues, val),
              resetValue: 0.0,
            ),
            const SizedBox(width: 20),
            buildMiniSlider(
              context,
              "LOW PASS",
              filterValue,
              (val) => sendFilter("FILTER_LPF", filterValues, val),
              resetValue: 1.0,
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            buildMiniSlider(
              context,
              "RES HIGH",
              resHpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_RES_HPF", resHpfValues, val),
              resetValue: 0.0,
            ),
            const SizedBox(width: 20),
            buildMiniSlider(
              context,
              "RES LOW",
              resLpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_RES_LPF", resLpfValues, val),
              resetValue: 0.0,
            ),
          ],
        ),
        const SizedBox(height: 16),
        // DIBUJO DEL FILTRO: misma curva e iluminacion que en FilterModule.cpp del synth,
        // con los 2 puntitos blancos arrastrables (HPF a la izquierda, LPF a la derecha).
        Expanded(
          child: FilterGraph(
            hpf: hpfValues[selectedLayer]!,
            resHpf: resHpfValues[selectedLayer]!,
            lpf: filterValue,
            resLpf: resLpfValues[selectedLayer]!,
            color: activeColor,
            onHpfChanged: (val) => sendFilter("FILTER_HPF", hpfValues, val),
            onResHpfChanged: (val) =>
                sendFilter("FILTER_RES_HPF", resHpfValues, val),
            onLpfChanged: (val) => sendFilter("FILTER_LPF", filterValues, val),
            onResLpfChanged: (val) =>
                sendFilter("FILTER_RES_LPF", resLpfValues, val),
            onDragActiveChanged: setDragLock,
          ),
        ),
      ],
    );
  }

  // --- WIDGET: PANEL "MIXER" (pagina 1 del panel deslizante) ---
  // Fader de volumen vertical + 4 knobs de EQ (2 arriba, 2 abajo), por capa.
  Widget buildMixerPanel(BuildContext context) {
    void sendEq(String suffix, Map<String, double> store, double val) {
      setState(() => store[selectedLayer] = val);
      sendOscMessage('/${selectedLayer}_$suffix', val);
    }

    return Column(
      children: [
        Row(
          // "start" (no "center"): asi ambas columnas arrancan a la misma
          // altura y el final del fader se puede alinear con precision con
          // el inicio de las etiquetas de la fila de abajo de knobs.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // FADER DE VOLUMEN VERTICAL: el final coincide con el inicio de las
            // etiquetas "MID-H"/"HIGH" de la rejilla de knobs.
            Column(
              children: [
                SizedBox(
                  height: 14,
                  child: Text(
                    "VOL",
                    style: TextStyle(
                      letterSpacing: 1.5,
                      color: activeColor.withOpacity(0.8),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onDoubleTap: () => sendEq("MIX_VOL", volValues, 0.75),
                  child: SizedBox(
                    height: 190,
                    width: 44,
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: activeColor,
                          inactiveTrackColor: Colors.white10,
                          trackHeight: 6.0,
                          thumbColor: activeColor,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 11.0,
                          ),
                          overlayColor: activeColor.withOpacity(0.2),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 22.0,
                          ),
                        ),
                        child: Slider(
                          value: volValues[selectedLayer]!,
                          min: 0.0,
                          max: 1.0,
                          onChanged: (val) => sendEq("MIX_VOL", volValues, val),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 24),
            // 4 KNOBS DE EQ: 2 ARRIBA, 2 ABAJO
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      RotaryKnob(
                        label: "LOW",
                        value: eqLowValues[selectedLayer]!,
                        color: activeColor,
                        size: 76,
                        resetValue: 0.5,
                        onChanged: (val) => sendEq("EQ_LOW", eqLowValues, val),
                      ),
                      RotaryKnob(
                        label: "MID-L",
                        value: eqMidLowValues[selectedLayer]!,
                        color: activeColor,
                        size: 76,
                        resetValue: 0.5,
                        onChanged: (val) =>
                            sendEq("EQ_MID_LOW", eqMidLowValues, val),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      RotaryKnob(
                        label: "MID-H",
                        value: eqMidHighValues[selectedLayer]!,
                        color: activeColor,
                        size: 76,
                        resetValue: 0.5,
                        onChanged: (val) =>
                            sendEq("EQ_MID_HIGH", eqMidHighValues, val),
                      ),
                      RotaryKnob(
                        label: "HIGH",
                        value: eqHighValues[selectedLayer]!,
                        color: activeColor,
                        size: 76,
                        resetValue: 0.5,
                        onChanged: (val) =>
                            sendEq("EQ_HIGH", eqHighValues, val),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // CURVA DE EQ DE 4 BANDAS: version visual nueva del mixer (el synth no
        // dibuja una curva aqui), a juego con el dibujo del filtro: misma
        // linea/relleno/halo de color de capa, con 4 puntitos blancos
        // arrastrables verticalmente (uno por banda).
        Expanded(
          child: EqCurve(
            low: eqLowValues[selectedLayer]!,
            midLow: eqMidLowValues[selectedLayer]!,
            midHigh: eqMidHighValues[selectedLayer]!,
            high: eqHighValues[selectedLayer]!,
            color: activeColor,
            onLowChanged: (val) => sendEq("EQ_LOW", eqLowValues, val),
            onMidLowChanged: (val) => sendEq("EQ_MID_LOW", eqMidLowValues, val),
            onMidHighChanged: (val) =>
                sendEq("EQ_MID_HIGH", eqMidHighValues, val),
            onHighChanged: (val) => sendEq("EQ_HIGH", eqHighValues, val),
            onDragActiveChanged: setDragLock,
          ),
        ),
      ],
    );
  }

  // --- WIDGET: PANEL "GRANULAR" (pagina 2 del panel deslizante) ---
  // Rejilla 3x3 de knobs (9 de los 12 parametros del motor granular) + la
  // ventana de grano debajo (Position, Grain Size y Shape, con un solo gesto).
  Widget buildEnginePanel(BuildContext context) {
    void sendEngine(String suffix, Map<String, double> store, double val) {
      setState(() => store[selectedLayer] = val);
      sendOscMessage('/${selectedLayer}_$suffix', val);
    }

    Widget knobRow(List<Widget> knobs) =>
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: knobs);

    // Solo 6 knobs aqui (Density, Scan, Spray): los 3 de Pitch (Trans/Fine/
    // Scale) se quitan de este engine, tendran su propio modulo mas adelante.
    // Con menos knobs, cada uno puede ser mas grande y queda mas espacio para
    // la ventana de grano de abajo.
    return Column(
      children: [
        knobRow([
          RotaryKnob(
            label: "DENSITY",
            value: densityValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.4,
            onChanged: (val) => sendEngine("DENSITY", densityValues, val),
          ),
          RotaryKnob(
            label: "SCAN SPD",
            value: scanSpeedValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.5,
            onChanged: (val) => sendEngine("SCAN_SPEED", scanSpeedValues, val),
          ),
          RotaryKnob(
            label: "SCAN DIR",
            value: scanModeValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.0,
            onChanged: (val) => sendEngine("SCAN_MODE", scanModeValues, val),
          ),
        ]),
        const SizedBox(height: 18),
        knobRow([
          RotaryKnob(
            label: "SPRAY POS",
            value: sprayPosValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.0,
            onChanged: (val) => sendEngine("SPRAY_POS", sprayPosValues, val),
          ),
          RotaryKnob(
            label: "SPRAY PITCH",
            value: sprayPitchValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.0,
            onChanged: (val) =>
                sendEngine("SPRAY_PITCH", sprayPitchValues, val),
          ),
          RotaryKnob(
            label: "SPRAY PAN",
            value: sprayPanValues[selectedLayer]!,
            color: activeColor,
            size: 72,
            resetValue: 0.0,
            onChanged: (val) => sendEngine("SPRAY_PAN", sprayPanValues, val),
          ),
        ]),
        const SizedBox(height: 16),
        // VENTANA DE GRANO: Position (arrastre horizontal, 1 dedo), Grain
        // Size (pellizcar, 2 dedos) y Shape (arrastre vertical, 1 dedo).
        Expanded(
          child: GrainWindow(
            position: positionValues[selectedLayer]!,
            grainSize: grainSizeValues[selectedLayer]!,
            shape: shapeValues[selectedLayer]!,
            color: activeColor,
            onPositionChanged: (val) =>
                sendEngine("POSITION", positionValues, val),
            onGrainSizeChanged: (val) =>
                sendEngine("GRAIN_SIZE", grainSizeValues, val),
            onShapeChanged: (val) => sendEngine("SHAPE", shapeValues, val),
            onDragActiveChanged: setDragLock,
          ),
        ),
      ],
    );
  }

  // --- WIDGET: PANEL "PITCH" (pagina 3 del panel deslizante) ---
  // Izquierda: TRANS (grande, con lectura en semitonos debajo) y FINE.
  // Derecha: 4 botones para PITCH_SCALE (los 4 modos de cuantizacion de
  // GranularVoice.cpp: Libre, Octavas, Quintas, Semitonos).
  Widget buildPitchPanel(BuildContext context) {
    void sendPitch(String suffix, Map<String, double> store, double val) {
      setState(() => store[selectedLayer] = val);
      sendOscMessage('/${selectedLayer}_$suffix', val);
    }

    // PITCH_TRANS: normalizado 0-1 -> rango real -24..+24 semitonos.
    final transNorm = pitchTransValues[selectedLayer]!;
    final semitones = (transNorm * 48.0 - 24.0).round();
    final semitoneLabel = semitones == 0
        ? "0 ST"
        : (semitones > 0 ? "+$semitones ST" : "$semitones ST");

    const scaleOptions = [
      (label: "FREE", sub: "continuo"),
      (label: "OCT", sub: "12 st"),
      (label: "5TH", sub: "7 st"),
      (label: "SEMI", sub: "1 st"),
    ];
    final scaleIndex = (pitchScaleValues[selectedLayer]! * 3.0).round().clamp(
      0,
      3,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // COLUMNA IZQUIERDA: TRANS (grande) + lectura en semitonos + FINE
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              RotaryKnob(
                label: "TRANS",
                value: transNorm,
                color: activeColor,
                size: 96,
                resetValue: 0.5,
                onChanged: (val) =>
                    sendPitch("PITCH_TRANS", pitchTransValues, val),
              ),
              const SizedBox(height: 6),
              Text(
                semitoneLabel,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1,
                  color: activeColor,
                ),
              ),
              const SizedBox(height: 26),
              RotaryKnob(
                label: "FINE",
                value: pitchFineValues[selectedLayer]!,
                color: activeColor,
                size: 64,
                resetValue: 0.5,
                onChanged: (val) =>
                    sendPitch("PITCH_FINE", pitchFineValues, val),
              ),
            ],
          ),
        ),
        const SizedBox(width: 20),
        // COLUMNA DERECHA: 4 botones de SCALE (cuantizacion en semitonos)
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(scaleOptions.length, (i) {
              final isActive = scaleIndex == i;
              final option = scaleOptions[i];
              return Padding(
                padding: EdgeInsets.only(
                  bottom: i == scaleOptions.length - 1 ? 0 : 10,
                ),
                child: GestureDetector(
                  onTap: () =>
                      sendPitch("PITCH_SCALE", pitchScaleValues, i / 3.0),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      color: isActive
                          ? activeColor.withOpacity(0.18)
                          : const Color(0xFF1A1A1D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isActive ? activeColor : Colors.white12,
                        width: isActive ? 1.5 : 1,
                      ),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: activeColor.withOpacity(0.35),
                                blurRadius: 12,
                                spreadRadius: 1,
                              ),
                            ]
                          : [],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          option.label,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            letterSpacing: 1.2,
                            color: isActive ? activeColor : Colors.white54,
                          ),
                        ),
                        Text(
                          option.sub,
                          style: TextStyle(
                            fontSize: 9,
                            color: isActive
                                ? activeColor.withOpacity(0.7)
                                : Colors.white24,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  // El PageView normal de los 4 engines, con la transicion de tamano/opacidad
  // entre paginas. Extraido a su propio metodo para poder alternarlo con el
  // menu de modulos dentro del mismo AnimatedSwitcher/recuadro.
  Widget _buildEnginePageView() {
    return PageView.builder(
      key: const ValueKey('enginePageView'),
      controller: enginePageController,
      // Se bloquea mientras se arrastra un puntito del filtro, la curva de
      // EQ o la ventana de grano, para que no compitan por el mismo gesto.
      physics: lockPageSwipe ? const NeverScrollableScrollPhysics() : null,
      onPageChanged: (page) => setState(() => currentEnginePage = page),
      itemCount: 4,
      itemBuilder: (context, index) {
        final page = switch (index) {
          0 => buildMixerPanel(context),
          1 => buildFilterPanel(context),
          2 => buildEnginePanel(context),
          _ => buildPitchPanel(context),
        };
        return AnimatedBuilder(
          animation: enginePageController,
          builder: (context, child) {
            double current = currentEnginePage.toDouble();
            if (enginePageController.hasClients &&
                enginePageController.page != null) {
              current = enginePageController.page!;
            }
            final distance = (current - index).abs().clamp(0.0, 1.0);
            final scale = 1.0 - (distance * 0.12);
            final fade = 1.0 - (distance * 0.5);
            return Opacity(
              opacity: fade,
              child: Transform.scale(scale: scale, child: child),
            );
          },
          // Con el candado puesto, esta pagina no responde a toques
          // (sliders/knobs/puntitos), pero el PageView que la contiene sigue
          // recibiendo el swipe normal.
          child: AbsorbPointer(absorbing: engineLocked, child: page),
        );
      },
    );
  }

  // Menu de modulos: sustituye al PageView DENTRO del mismo recuadro (no un
  // popup aparte), retro-futurista, con las opciones siempre iluminadas del
  // color de la capa activa. Tocar una opcion vuelve a la pantalla de
  // engines ya en ese modulo.
  Widget buildModuleMenuOverlay(BuildContext context) {
    const items = [
      (label: "MIXER", icon: Icons.tune_rounded),
      (label: "FILTER", icon: Icons.show_chart_rounded),
      (label: "GRANULAR", icon: Icons.grain_rounded),
      (label: "PITCH", icon: Icons.piano_rounded),
    ];

    return Column(
      key: const ValueKey('moduleMenu'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(items.length, (i) {
        final isActive = currentEnginePage == i;
        final item = items[i];
        return Padding(
          padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 14),
          child: GestureDetector(
            onTap: () {
              enginePageController.jumpToPage(i);
              setState(() {
                currentEnginePage = i;
                showModuleMenu = false;
              });
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: isActive
                    ? activeColor.withOpacity(0.15)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: activeColor.withOpacity(isActive ? 0.9 : 0.35),
                  width: isActive ? 1.5 : 1,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: activeColor.withOpacity(0.4),
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ]
                    : [],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    item.icon,
                    size: 18,
                    color: activeColor.withOpacity(isActive ? 1.0 : 0.6),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    item.label,
                    style: TextStyle(
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: activeColor.withOpacity(isActive ? 1.0 : 0.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        // ShaderMask: difumina el borde inferior en vez de cortarlo en seco,
        // asi el REC/Play que asoma al abrir la app se ve como una pista de
        // "desliza para ver mas", no como un recorte brusco.
        child: ShaderMask(
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0.0, 0.93, 1.0],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          // SingleChildScrollView evita el desbordamiento (franja amarilla/negra
          // de Flutter) en pantallas mas bajas o al rotar, en vez de recortar el contenido.
          // Tambien se bloquea mientras se arrastra un puntito: si no, un
          // arrastre vertical sobre el filtro/EQ tambien hacia scroll en toda
          // la pantalla a la vez.
          child: SingleChildScrollView(
            physics: lockPageSwipe
                ? const NeverScrollableScrollPhysics()
                : null,
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 20.0,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // HEADER
                Text(
                  "GRANULAR REMOTE",
                  style: TextStyle(
                    letterSpacing: 4,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    color: Colors.white.withOpacity(0.9),
                  ),
                ),
                const SizedBox(height: 30),

                // CAJA DE IP (Estilo Display Digital)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121215),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: TextField(
                    controller: ipController,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 18,
                      color: Colors.white70,
                    ),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      labelText: "TARGET IP ADDRESS",
                      labelStyle: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        letterSpacing: 2,
                      ),
                      floatingLabelAlignment: FloatingLabelAlignment.center,
                    ),
                  ),
                ),
                const SizedBox(height: 40),

                // SELECTOR DE CAPAS
                const Text(
                  "TARGET LAYER",
                  style: TextStyle(
                    color: Colors.grey,
                    letterSpacing: 2,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  height:
                      80, // Fija el alto para que la animación no empuje el resto de elementos
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      buildColorPad("L1", Colors.cyanAccent),
                      buildColorPad("L2", Colors.pinkAccent),
                      buildColorPad("L3", Colors.orangeAccent),
                      buildColorPad("L4", Colors.lightGreenAccent),
                    ],
                  ),
                ),
                // Antes era un Spacer flexible; con SingleChildScrollView necesita
                // alto fijo, y de paso separa los L1-L4 de la caja de abajo.
                const SizedBox(height: 40),

                // PANEL CENTRAL DESLIZANTE (MIXER <-> FILTRO)
                // AnimatedOpacity: cuando el candado esta activado, toda esta
                // caja se ve un poco apagada para dejar claro que esta bloqueada.
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: engineLocked ? 0.5 : 1.0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    height: 380,
                    padding: const EdgeInsets.all(25),
                    decoration: BoxDecoration(
                      color: const Color(0xFF16161A),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: activeColor.withOpacity(0.3),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: activeColor.withOpacity(0.05),
                          blurRadius: 40,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    // AnimatedSwitcher: el propio recuadro alterna entre el
                    // PageView normal y el menu de modulos (elegante, sin
                    // abrir un popup aparte fuera de la caja).
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: showModuleMenu
                          ? buildModuleMenuOverlay(context)
                          : _buildEnginePageView(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // PUNTOS INDICADORES + BOTON DE MENU (izq.) Y CANDADO (dcha.)
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(4, (i) {
                        final isActive = currentEnginePage == i;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: isActive ? 18 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: isActive ? activeColor : Colors.white24,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        );
                      }),
                    ),
                    // BOTON DE MENU DE MODULOS (izquierda, simetrico al candado)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => showModuleMenu = !showModuleMenu),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: showModuleMenu
                                ? activeColor.withOpacity(0.15)
                                : const Color(0xFF1A1A1D),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: showModuleMenu
                                  ? activeColor
                                  : Colors.white12,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            Icons.apps_rounded,
                            size: 16,
                            color: showModuleMenu
                                ? activeColor
                                : Colors.white38,
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: GestureDetector(
                        onTap: () =>
                            setState(() => engineLocked = !engineLocked),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: engineLocked
                                ? activeColor.withOpacity(0.15)
                                : const Color(0xFF1A1A1D),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: engineLocked
                                  ? activeColor
                                  : Colors.white12,
                              width: 1.5,
                            ),
                          ),
                          child: Icon(
                            engineLocked ? Icons.lock : Icons.lock_open,
                            size: 16,
                            color: engineLocked ? activeColor : Colors.white38,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // Separa la caja deslizante + puntos del boton de REC de abajo.
                const SizedBox(height: 36),

                // BOTON DE REC + BOTON DE PLAY (Play a la derecha del REC, un poco mas pequeno)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: toggleRecording,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        height: 110,
                        width: 110,
                        decoration: BoxDecoration(
                          color: isRecording
                              ? Colors.redAccent
                              : const Color(0xFF1A1A1D),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isRecording ? Colors.red : Colors.white12,
                            width: isRecording ? 0 : 3,
                          ),
                          boxShadow: isRecording
                              ? [
                                  const BoxShadow(
                                    color: Colors.redAccent,
                                    blurRadius: 40,
                                    spreadRadius: 10,
                                  ),
                                ]
                              : [
                                  const BoxShadow(
                                    color: Colors.black54,
                                    blurRadius: 10,
                                    offset: Offset(0, 5),
                                  ),
                                ],
                        ),
                        child: Center(
                          child: Text(
                            isRecording ? "STOP" : "REC",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              color: isRecording
                                  ? Colors.white
                                  : Colors.redAccent,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 30),
                    buildPlayButton(),
                  ],
                ),
                const SizedBox(height: 20),
                Text(
                  isRecording ? "TAP TO SEND TO PLUGIN" : "TAP TO RECORD AUDIO",
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<String> getApplicationDocumentsPath() async {
    final directory = await getTemporaryDirectory();
    return directory.path;
  }
}
