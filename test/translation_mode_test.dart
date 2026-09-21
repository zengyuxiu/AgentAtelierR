import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/app_localization.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'independent performance preserves Kemini ordering and runtime language',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        final plan = controller.buildCharacterPromptPlan(
          independentPerformance: true,
        );
        expect(plan.preview, contains('<Interleaved_thinking>'));
        expect(plan.preview, contains('不少于1000字'));
        expect(plan.performanceProtocol, contains('表演由独立模块处理'));
        expect(plan.performanceProtocol, isNot(contains('必须且只能有一组头部')));
        expect(plan.performanceProtocol, contains('不要输出译文行'));
        controller.setIndependentTranslation(false);
        controller.translationLanguage = TranslationLanguage.chinese;
        expect(
          controller
              .buildCharacterPromptPlan(independentPerformance: true)
              .performanceProtocol,
          contains('每条莱莎及其他角色台词之后紧跟一行'),
        );
        controller.setIndependentTranslation(true);
      }
    },
  );
  test('translation mode controls every prompt path and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await AppController.load();
    controller.translationLanguage = TranslationLanguage.chinese;
    expect(controller.independentTranslation, isTrue);
    for (final independent in [false, true]) {
      expect(
        controller.buildCharacterPrompt(independentPerformance: independent),
        contains('不要输出译文行'),
      );
    }
    controller.setIndependentTranslation(false);
    for (final independent in [false, true]) {
      final prompt = controller.buildCharacterPrompt(
        independentPerformance: independent,
      );
      expect(prompt, contains('每条莱莎及其他角色台词之后紧跟一行'));
      expect(prompt, isNot(contains('不要输出译文')));
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final restored = await AppController.load();
    expect(restored.independentTranslation, isFalse);
    expect(restored.exportData()['independentTranslation'], isFalse);
    controller.translationLanguage = TranslationLanguage.none;
    expect(
      controller.buildCharacterPrompt(independentPerformance: true),
      contains('不要输出译文行'),
    );
    controller.dispose();
    restored.dispose();
  });
}
