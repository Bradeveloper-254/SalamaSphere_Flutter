import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/main.dart';
import 'package:salamasphere_mobile/services/api_service.dart';

void main() {
  testWidgets('SalamaSphere app starts successfully', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(SalamaSphereApp(apiService: ApiService()));

    expect(find.text('SalamaSphere'), findsWidgets);
  });
}