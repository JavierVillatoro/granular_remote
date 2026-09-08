import 'package:flutter/material.dart';
import 'dart:async';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:osc/osc.dart';
import 'dart:io';
import 'widgets/rotary_knob.dart';
import 'widgets/filter_graph.dart';

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
  Widget buildMiniSlider(
    BuildContext context,
    String label,
    double value,
    ValueChanged<double> onChanged,
  ) {
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
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: activeColor,
              inactiveTrackColor: Colors.white10,
              trackHeight: 5.0,
              thumbColor: activeColor,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9.0),
              overlayColor: activeColor.withOpacity(0.2),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 18.0),
            ),
            child: Slider(
              value: value,
              min: 0.0,
              max: 1.0,
              onChanged: onChanged,
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

    return Column(
      children: [
        Row(
          children: [
            buildMiniSlider(
              context,
              "LOW PASS",
              filterValue,
              (val) => sendFilter("FILTER_LPF", filterValues, val),
            ),
            const SizedBox(width: 20),
            buildMiniSlider(
              context,
              "HIGH PASS",
              hpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_HPF", hpfValues, val),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            buildMiniSlider(
              context,
              "RES LOW",
              resLpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_RES_LPF", resLpfValues, val),
            ),
            const SizedBox(width: 20),
            buildMiniSlider(
              context,
              "RES HIGH",
              resHpfValues[selectedLayer]!,
              (val) => sendFilter("FILTER_RES_HPF", resHpfValues, val),
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

    return Row(
      // "start" (no "center"): asi ambas columnas arrancan a la misma altura
      // y el final del fader se puede alinear con precision con el inicio
      // de las etiquetas de la fila de abajo de knobs.
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
            SizedBox(
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
                    onChanged: (val) => sendEq("EQ_LOW", eqLowValues, val),
                  ),
                  RotaryKnob(
                    label: "MID-L",
                    value: eqMidLowValues[selectedLayer]!,
                    color: activeColor,
                    size: 76,
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
                    onChanged: (val) =>
                        sendEq("EQ_MID_HIGH", eqMidHighValues, val),
                  ),
                  RotaryKnob(
                    label: "HIGH",
                    value: eqHighValues[selectedLayer]!,
                    color: activeColor,
                    size: 76,
                    onChanged: (val) => sendEq("EQ_HIGH", eqHighValues, val),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
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
          child: SingleChildScrollView(
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
                AnimatedContainer(
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
                  child: PageView(
                    controller: enginePageController,
                    onPageChanged: (page) =>
                        setState(() => currentEnginePage = page),
                    children: [
                      buildMixerPanel(context),
                      buildFilterPanel(context),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // PUNTOS INDICADORES DE PAGINA
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(2, (i) {
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
