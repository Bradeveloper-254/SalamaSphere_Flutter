import 'package:flutter_test/flutter_test.dart';
import 'package:salamasphere_mobile/main.dart';

void main() {
  testWidgets('SalamaSphere app starts successfully', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SalamaSphereApp());

    expect(find.text('SalamaSphere'), findsWidgets);
  });
}