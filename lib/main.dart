import 'package:flutter/material.dart';

import 'src/controller.dart';
import 'src/workspace.dart';
import 'src/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ScreenClipApp());
}

class ScreenClipApp extends StatefulWidget {
  const ScreenClipApp({super.key});
  @override
  State<ScreenClipApp> createState() => _ScreenClipAppState();
}

class _ScreenClipAppState extends State<ScreenClipApp> {
  final controller = ClipController();
  @override
  void initState() {
    super.initState();
    controller.initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      title: '定格T',
      debugShowCheckedModeBanner: false,
      themeMode: controller.themeMode,
      theme: screenClipTheme(Brightness.light),
      darkTheme: screenClipTheme(Brightness.dark),
      home: Workspace(controller: controller),
    ),
  );
}
