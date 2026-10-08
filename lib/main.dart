import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';
import 'controllers/app_controller.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Decoded images are the largest part of the UI's memory; the default
  // cache (100 MB) mostly held stale screen previews.
  PaintingBinding.instance.imageCache
    ..maximumSize = 60
    ..maximumSizeBytes = 32 << 20;
  // Flutter sizes its GPU cache at twelve full frames — about 200 MB on a
  // HiDPI screen, and on integrated graphics that is system memory. This UI
  // is flat surfaces and text, which redraw cheaply: 16 MB measured about
  // 40 MB less memory at idle than 48 MB.
  unawaited(
    SystemChannels.skia.invokeMethod<void>(
      'Skia.setResourceCacheMaxBytes',
      16 << 20,
    ),
  );
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: Size(1240, 840),
          minimumSize: Size(800, 600),
          center: true,
          title: 'Ramizom Magic Wand',
          backgroundColor: Color(0xFFFFFFFF),
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }
  runApp(const MagicWandApp());
}

class MagicWandApp extends StatefulWidget {
  const MagicWandApp({super.key, this.controller});
  final AppController? controller;
  @override
  State<MagicWandApp> createState() => _MagicWandAppState();
}

class _MagicWandAppState extends State<MagicWandApp> {
  late final AppController controller = widget.controller ?? AppController();
  @override
  void initState() {
    super.initState();
    if (widget.controller == null) unawaited(controller.initialize());
  }

  @override
  void dispose() {
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => MaterialApp(
      title: 'Ramizom Magic Wand',
      debugShowCheckedModeBanner: false,
      themeAnimationDuration: const Duration(milliseconds: 350),
      themeAnimationCurve: Curves.easeInOutCubic,
      theme: buildMagicWandTheme(accentColor: controller.settings.accentColor),
      darkTheme: buildMagicWandTheme(
        brightness: Brightness.dark,
        accentColor: controller.settings.accentColor,
      ),
      themeMode: switch (controller.settings.theme) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      },
      locale: controller.strings.locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: HomeScreen(controller: controller),
    ),
  );
}
