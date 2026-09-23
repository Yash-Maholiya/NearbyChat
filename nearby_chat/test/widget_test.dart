import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_chat/controllers/chat_controller.dart';
import 'package:nearby_chat/main.dart';
import 'package:nearby_chat/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('NearbyChatApp loads SetupScreen on first launch', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    final storage = await StorageService.create();
    final controller = ChatController(storage: storage);
    await controller.init();

    await tester.pumpWidget(NearbyChatApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('NearbyChat'), findsWidgets);
    expect(find.text('Choose Your Display Name'), findsOneWidget);
    expect(find.text('Generate Keys & Continue'), findsOneWidget);
  });
}
