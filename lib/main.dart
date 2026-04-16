import 'package:flutter/material.dart';
import 'dart:async';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:osc/osc.dart'; 
import 'dart:io';

void main() => runApp(const GranularRemoteApp());

class GranularRemoteApp extends StatelessWidget {
  const GranularRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false, // Quitamos la etiqueta molesta de Debug
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xff0A0A0C), // Negro más profundo y elegante
        appBarTheme: const AppBarTheme(backgroundColor: Color(0xff0A0A0C), elevation: 0),
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
  final TextEditingController ipController = TextEditingController(text: "192.168.1.100");
  
  String selectedLayer = "L1";
  bool isRecording = false;
  bool isPlaying = false;
  double filterValue = 1.0;

  // --- LÓGICA DE COLOR DINÁMICO ---
  // Esta función devuelve el color exacto dependiendo de la capa activa
  Color get activeColor {
    switch (selectedLayer) {
      case "L1": return Colors.cyanAccent;
      case "L2": return Colors.pinkAccent;
      case "L3": return Colors.orangeAccent;
      case "L4": return Colors.lightGreenAccent;
      default: return Colors.cyanAccent;
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
        headers: { 'Content-Type': 'audio/wav', 'layer': selectedLayer },
        body: fileBytes,
      );
      if (response.statusCode == 200) print("Audio enviado con éxito a la capa $selectedLayer");
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
        await audioRecorder.start(const RecordConfig(encoder: AudioEncoder.wav), path: path);
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
    setState(() => isPlaying = !isPlaying);
    sendOscMessage('/${selectedLayer}_PLAY', isPlaying ? 1.0 : 0.0);
  }

  // --- WIDGET: PAD DE COLOR ---
  Widget buildColorPad(String layerName, Color baseColor) {
    bool isSelected = selectedLayer == layerName;
    return GestureDetector(
      onTap: () {
        // Al tocar, abrimos llaves para hacer múltiples acciones:
        setState(() => selectedLayer = layerName); // 1. Cambia visualmente en el móvil
        
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
          color: isSelected ? baseColor.withOpacity(0.15) : const Color(0xFF1A1A1D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? baseColor : Colors.white10, 
            width: isSelected ? 2 : 1
          ),
          boxShadow: isSelected ? [BoxShadow(color: baseColor.withOpacity(0.4), blurRadius: 20, spreadRadius: 2)] : [],
        ),
        child: Center(
          child: Text(layerName, 
            style: TextStyle(
              fontWeight: FontWeight.bold, 
              fontSize: isSelected ? 20 : 16, 
              color: isSelected ? baseColor : Colors.white54
            )
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // HEADER
              Text("GRANULAR REMOTE", style: TextStyle(letterSpacing: 4, fontWeight: FontWeight.w900, fontSize: 22, color: Colors.white.withOpacity(0.9))),
              const SizedBox(height: 30),

              // CAJA DE IP (Estilo Display Digital)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF121215),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: TextField(
                  controller: ipController,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 18, color: Colors.white70),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    labelText: "TARGET IP ADDRESS",
                    labelStyle: TextStyle(fontSize: 12, color: Colors.grey, letterSpacing: 2),
                    floatingLabelAlignment: FloatingLabelAlignment.center,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              
              // SELECTOR DE CAPAS
              const Text("TARGET LAYER", style: TextStyle(color: Colors.grey, letterSpacing: 2, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              SizedBox(
                height: 80, // Fija el alto para que la animación no empuje el resto de elementos
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
              const Spacer(),

              // PANEL CENTRAL (PLAY Y FILTRO)
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  color: const Color(0xFF16161A),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: activeColor.withOpacity(0.3), width: 1),
                  boxShadow: [BoxShadow(color: activeColor.withOpacity(0.05), blurRadius: 40, spreadRadius: 5)],
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("PLAY ENGINE", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white70)),
                        Switch(
                          value: isPlaying,
                          activeColor: activeColor, // Color dinámico
                          activeTrackColor: activeColor.withOpacity(0.3),
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.white10,
                          onChanged: (val) => togglePlay(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 30),
                    Text("LOW PASS FILTER", style: TextStyle(letterSpacing: 2, color: activeColor.withOpacity(0.8), fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    // SLIDER PREMIUM
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: activeColor,
                        inactiveTrackColor: Colors.white10,
                        trackHeight: 6.0,
                        thumbColor: activeColor,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12.0),
                        overlayColor: activeColor.withOpacity(0.2),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 24.0),
                      ),
                      child: Slider(
                        value: filterValue,
                        min: 0.0,
                        max: 1.0,
                        onChanged: (val) {
                          setState(() => filterValue = val);
                          sendOscMessage('/${selectedLayer}_FILTER_LPF', val);
                        },
                      ),
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // BOTÓN DE REC (Estilo Hardware)
              GestureDetector(
                onTap: toggleRecording, 
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  height: 110, width: 110,
                  decoration: BoxDecoration(
                    color: isRecording ? Colors.redAccent : const Color(0xFF1A1A1D),
                    shape: BoxShape.circle,
                    border: Border.all(color: isRecording ? Colors.red : Colors.white12, width: isRecording ? 0 : 3),
                    boxShadow: isRecording 
                        ? [const BoxShadow(color: Colors.redAccent, blurRadius: 40, spreadRadius: 10)] 
                        : [const BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 5))],
                  ),
                  child: Center(
                    child: Text(isRecording ? "STOP" : "REC", 
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: isRecording ? Colors.white : Colors.redAccent, letterSpacing: 2)),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(isRecording ? "TAP TO SEND TO PLUGIN" : "TAP TO RECORD AUDIO", style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1.5)),
            ],
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
