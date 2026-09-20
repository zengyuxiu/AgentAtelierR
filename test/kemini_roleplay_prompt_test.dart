import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/chat_segments.dart';
import 'package:ryza_chat_mvp/src/character_performance.dart';
import 'package:ryza_chat_mvp/src/vertex_ai.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:http/http.dart' as http;

import 'dart:convert';

/// Capture only the Vertex model request body, never OAuth or headers.
class _RequestRecorder extends http.BaseClient {
  final http.Client inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request &&
        request.url.host.endsWith('aiplatform.googleapis.com')) {
      await File('/tmp/agentatelier-kemini-request.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(jsonDecode(request.body)),
      );
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

CharacterPerformancePromptContext capability(AppController controller) =>
    CharacterPerformancePromptContext(
      appearanceId: controller.selectedCharacterAppearanceId,
      posture: 'sitting_normal',
      revision: 1,
      resourcesReady: true,
      playableActionDescriptions: const {'none': '本段不发起新的主要动作。'},
      postureManuallySelected: true,
    );

void validateScript(String text) {
  final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
  expect(lines, isNotEmpty);
  for (final line in lines) {
    expect(line, matches(r'^(旁白|莱莎|角色\[[^\]]+\]|译文)：'));
    if (line.startsWith('莱莎：')) {
      expect(
        line,
        matches(
          r'^莱莎：\[[a-z -]+\]\[face:(neutral|happy|laughing|angry|sad|crying|shy|tease|cuddle)\]\[action:none\]',
        ),
      );
    } else {
      expect(line, isNot(contains('[face:')));
      expect(line, isNot(contains('[action:')));
    }
  }
  expect(text, isNot(contains('<thinking>')));
  expect(text, isNot(contains('<Interleaving>')));
  final segments = parseAssistantSegments(text);
  expect(segments.any((s) => s.speaker == ChatSpeaker.narrator), true);
  final dialogue = segments
      .where((s) => s.speaker == ChatSpeaker.ryza)
      .toList();
  expect(dialogue, isNotEmpty);
  final performance = performanceSegmentsForAssistantResponse(
    text,
    fallbackMood: CharacterMood.neutral,
  );
  expect(performance.length, dialogue.length);
  expect(
    performance.every(
      (p) => p.expression != null && p.action == CharacterAction.none,
    ),
    true,
  );
  for (final part in performance) {
    expect(part.speechText, isNot(contains('[face:')));
    expect(part.speechText, isNot(contains('[action:')));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Kemini leads full and compact prompts without replacing runtime facts',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        final prompt = controller.buildCharacterPrompt(
          performanceContext: capability(controller),
        );
        expect(
          prompt,
          contains('[d07b0943-0502-41b7-b126-a15998d4eca0 / user]'),
        );
        expect(prompt, contains('<Interleaved_thinking>'));
        expect(prompt, contains('视觉小说'));
        expect(prompt, contains('第三人称'));
        expect(prompt, contains('不少于1000字'));
        expect(prompt, contains('postureManuallySelected=true'));
        expect(prompt, contains('action:none'));
        expect(prompt, contains('narratorBodyLanguage'));
        expect(prompt, isNot(contains('{{getvar')));
        expect(prompt, isNot(contains('{{setvar')));
        expect(
          prompt,
          isNot(contains('ALL PREVIOUS PROMPT')),
        ); // User disabled CLEAR.
      }
      expect(
        controller.buildUserReplySuggestionPrompt(),
        isNot(contains('Interleaved_thinking')),
      );
    },
  );

  test('fictional inner narration never becomes spoken Ryza dialogue', () {
    const script =
        '旁白：莱莎忽然觉得，今天慢一点也挺好。\n'
        '莱莎：[relaxed][face:happy][action:none]今天就陪你聊聊。\n'
        '角色[test_npc]：那我先去整理材料。\n'
        '译文：Then I will sort the materials.\n'
        '旁白：那点急着出发的念头暂时被莱莎放到了一边。\n'
        '莱莎：[calm][face:neutral][action:none]嗯，事情可以一件件来。';
    validateScript(script);
    final speech = performanceSegmentsForAssistantResponse(
      script,
      fallbackMood: CharacterMood.neutral,
    ).map((s) => s.speechText).join();
    expect(speech, isNot(contains('今天慢一点')));
    expect(speech, isNot(contains('整理材料')));
    expect(speech, isNot(contains('Then I will')));
  });

  const keyFile = String.fromEnvironment('VERTEX_SERVICE_ACCOUNT_FILE');
  test(
    'live Vertex generation produces a playable Kemini script',
    () async {
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      final json = await File(keyFile).readAsString();
      final account = VertexServiceAccount.parse(json);
      // Flutter unit tests replace HTTP with a 400 stub. Only this explicitly
      // opted-in live test uses the real transport; restore it afterwards.
      final previousHttpOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousHttpOverrides);
      final recorder = _RequestRecorder();
      addTearDown(recorder.close);
      final client = VertexAiClient(client: recorder);
      addTearDown(client.close);
      const input = '今天不想赶路，陪我安静地聊一会儿吧。请写不少于1000字的完整剧情，用角色内心和对话展开，不替我说话或行动。';
      final plan = controller.buildCharacterPromptPlan(
        currentInput: input,
        performanceContext: capability(controller),
      );
      await File('/tmp/agentatelier-kemini-effective.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(plan.effectiveDocument),
      );
      final response = await OpenAiCompatibleClient(vertexClient: client)
          .streamChat(
            provider: LlmProvider.vertexAi,
            baseUrl: VertexAiConfig(projectId: account.projectId).baseUrl,
            apiKey: json,
            model: 'gemini-2.5-flash',
            systemPrompt: '',
            promptPlan: plan,
            messages: const [ChatMessage(text: input, isUser: true)],
            thinkingEnabled: false,
          )
          .join();
      await File('/tmp/agentatelier-kemini-sample.txt').writeAsString(response);
      validateScript(response);
      expect(response.length, greaterThan(1000));
    },
    skip: keyFile.isEmpty
        ? 'Set VERTEX_SERVICE_ACCOUNT_FILE to run the paid live smoke test.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
