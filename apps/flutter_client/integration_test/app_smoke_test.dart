import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:readarc/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ReadArc boots into the library without an uncaught Flutter error', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final previousHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousHandler);

    await tester.pumpWidget(const app.ReadArcApp());
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(app.LibraryScreen), findsOneWidget);
    expect(errors, isEmpty, reason: 'ReadArc emitted a Flutter framework error during startup: $errors');
  });
}
