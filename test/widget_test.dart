import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:umbraw_tray/main.dart';

void main() {
  testWidgets('shows the empty state', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 780));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const UmbrawTrayApp(autoScan: false));
    expect(find.text('Umbraw Tray'), findsOneWidget);
    expect(find.text('SOURCES'), findsOneWidget);
    expect(find.text('DESTINATION'), findsOneWidget);
    expect(find.text('Choose…'), findsOneWidget);
    expect(find.text('Imported files will appear here.'), findsOneWidget);
  });
}
