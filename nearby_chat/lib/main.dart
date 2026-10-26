import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'controllers/chat_controller.dart';
import 'screens/nearby_people_screen.dart';
import 'screens/setup_screen.dart';
import 'services/ble_service.dart';
import 'services/crypto_service.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  final controller = ChatController(
    crypto: CryptoService(),
    storage: await StorageService.create(),
    ble: BleService(),
  );
  await controller.init();
  runApp(NearbyChatApp(controller: controller));
}

class NearbyChatApp extends StatefulWidget {
  final ChatController controller;

  const NearbyChatApp({super.key, required this.controller});

  @override
  State<NearbyChatApp> createState() => _NearbyChatAppState();
}

class _NearbyChatAppState extends State<NearbyChatApp> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  late int _alertsShown = widget.controller.securityAlertCount;

  ChatController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChange);
  }

  @override
  void dispose() {
    controller.removeListener(_onChange);
    super.dispose();
  }

  // Security events (a tampered message, for now) get a red banner on whatever screen is open.
  void _onChange() {
    if (controller.securityAlertCount == _alertsShown) return;
    _alertsShown = controller.securityAlertCount;
    _messenger.currentState?.showSnackBar(SnackBar(
      backgroundColor: Colors.red.shade700,
      duration: const Duration(seconds: 8),
      content: Row(children: [
        const Icon(Icons.gpp_bad, color: Colors.white),
        const SizedBox(width: 12),
        Expanded(child: Text(controller.securityAlert ?? '', style: const TextStyle(color: Colors.white))),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NearbyChat',
      scaffoldMessengerKey: _messenger,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: Border(bottom: BorderSide(color: Color(0xFFDDDDDD))),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: controller.isRegistered
          ? NearbyPeopleScreen(controller: controller)
          : SetupScreen(controller: controller),
    );
  }
}
