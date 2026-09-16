import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/engine/model_catalog.dart';
import 'package:pocket_asr/features/models/model_library.dart';
import 'package:pocket_asr/main.dart';

void main() {
  ModelLibrary emptyLibrary() {
    final directory = Directory.systemTemp.createTempSync('pocket_asr_shell');
    addTearDown(() => directory.deleteSync(recursive: true));
    return ModelLibrary.fixed(
      entries: const [],
      store: LocalModelStore(directory),
    );
  }

  ModelLibrary libraryWithModel() {
    final directory = Directory.systemTemp.createTempSync('pocket_asr_shell');
    addTearDown(() => directory.deleteSync(recursive: true));
    final store = LocalModelStore(directory);
    const model = ModelEntry(
      id: 'sensevoice',
      displayName: 'SenseVoice Small',
      fileName: 'model.onnx',
      engine: 'sherpa',
      family: 'sensevoice',
      quant: 'int8',
    );
    File(store.pathFor(model))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1]);
    return ModelLibrary.fixed(entries: const [model], store: store);
  }

  testWidgets('five tabs, and Settings overrides locale + theme', (
    tester,
  ) async {
    await tester.pumpWidget(PocketAsrApp(modelLibrary: emptyLibrary()));

    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Transcribe'), findsWidgets);

    // Follow-the-system by default.
    MaterialApp app() => tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app().themeMode, ThemeMode.system);
    expect(app().locale, isNull);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    expect(app().locale, const Locale('zh'));
    expect(find.text('设置'), findsWidgets);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(app().themeMode, ThemeMode.dark);
  });

  testWidgets('empty model picker opens the Models tab', (tester) async {
    await tester.pumpWidget(PocketAsrApp(modelLibrary: emptyLibrary()));

    final chooseModel = find.text('Choose downloaded model');
    await tester.ensureVisible(chooseModel);
    await tester.tap(chooseModel);
    await tester.pumpAndSettle();
    expect(
      find.text('No downloaded speech models. Download one from Models first.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Open Models'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      3,
    );
    expect(find.text('Speech models'), findsNothing);
    expect(find.text('No models available'), findsOneWidget);
  });

  testWidgets('selected model is shared with the Queue tab', (tester) async {
    await tester.pumpWidget(PocketAsrApp(modelLibrary: libraryWithModel()));

    final chooseModel = find.text('Choose downloaded model');
    await tester.ensureVisible(chooseModel);
    await tester.tap(chooseModel);
    await tester.pumpAndSettle();
    await tester.tap(find.text('SenseVoice Small'));
    await tester.pumpAndSettle();

    expect(find.text('SenseVoice Small'), findsOneWidget);
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();
    expect(find.text('SenseVoice Small'), findsOneWidget);
  });
}
