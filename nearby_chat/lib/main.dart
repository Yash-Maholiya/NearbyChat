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

  // Enforce system UI overlay style for dark theme
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0B0F19),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final storageService = await StorageService.create();
  final cryptoService = CryptoService();
  final bleService = BleService();

  final chatController = ChatController(
    crypto: cryptoService,
    storage: storageService,
    ble: bleService,
  );

  await chatController.init();

  runApp(NearbyChatApp(controller: chatController));
}

class NearbyChatApp extends StatelessWidget {
  final ChatController controller;

  const NearbyChatApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NearbyChat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF10B981),
          surface: Color(0xFF111827),
          error: Color(0xFFEF4444),
          onPrimary: Colors.white,
          onSecondary: Colors.white,
          onSurface: Color(0xFFF9FAFB),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111827),
          elevation: 0,
          centerTitle: false,
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      home: controller.isRegistered
          ? NearbyPeopleScreen(controller: controller)
          : SetupScreen(controller: controller),
    );
  }
}
