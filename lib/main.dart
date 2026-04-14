import 'package:flutter/material.dart';
import 'dart:async';
import 'package:record/record.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

void main() => runApp(const GranularRemoteApp());

class GranularRemoteApp extends StatelessWidget {
  const GranularRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xff121212),
        primaryColor: Colors.cyan,
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

// ... (tus imports igual)

// Reemplaza tu clase _RemoteScreenState por esta:
class _RemoteScreenState extends State<RemoteScreen> {
  final AudioRecorder audioRecorder = AudioRecorder();
  final TextEditingController ipController = TextEditingController(text: "192.168.3.153"); // Tu IP de la captura
  String selectedLayer = "L1";
  bool isRecording = false;

  // Enviar audio como BYTES PUROS (para que tu JUCE lo entienda fácil)
  Future<void> sendAudioToPlugin(String filePath) async {
    final url = Uri.parse('http://${ipController.text}:8080');
    try {
      final fileBytes = await File(filePath).readAsBytes();
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'audio/wav',
          'layer': selectedLayer, // Pasamos la capa en la cabecera
        },
        body: fileBytes,
      );

      if (response.statusCode == 200) {
        print("¡Audio enviado con éxito!");
      }
    } catch (e) {
      print("Error de envío: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ... (tu AppBar igual)
      body: Padding(
        padding: const EdgeInsets.all(25.0),
        child: Column(
          children: [
            TextField(
              controller: ipController,
              decoration: const InputDecoration(labelText: "PLUGIN IP ADDRESS"),
            ),
            // ... (tu Dropdown igual)
            const Spacer(),
            GestureDetector(
              onLongPressStart: (_) async {
                if (await audioRecorder.hasPermission()) {
                  final directory = await getApplicationDocumentsPath();
                  final path = '$directory/temp_audio.wav';
                  
                  // CONFIGURACIÓN DE GRABACIÓN REAL
                  const config = RecordConfig(encoder: AudioEncoder.wav);
                  
                  await audioRecorder.start(config, path: path);
                  setState(() => isRecording = true);
                }
              },
              onLongPressEnd: (_) async {
                final path = await audioRecorder.stop();
                setState(() => isRecording = false);
                if (path != null) {
                  print("Grabación finalizada en: $path");
                  sendAudioToPlugin(path);
                }
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 150, width: 150,
                decoration: BoxDecoration(
                  color: isRecording ? Colors.red : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.red, width: 4),
                ),
                child: Center(child: Text(isRecording ? "REC" : "HOLD")),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Future<String> getApplicationDocumentsPath() async {
    final directory = await getTemporaryDirectory();
    return directory.path;
  }
}
