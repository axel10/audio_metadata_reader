// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('Metadata editor smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Check that we render either the empty state or the editor UI title.
    final emptyState = find.text('No Audio File Loaded');
    final editorState = find.text('Metadata Info');
    
    expect(emptyState.evaluate().isNotEmpty || editorState.evaluate().isNotEmpty, isTrue);
  });
}

