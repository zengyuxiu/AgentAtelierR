import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/kemini_disclaimer.dart';
import 'package:ryza_chat_mvp/src/kemini_preset.dart';
import 'package:ryza_chat_mvp/src/preset_wire.dart';
import 'package:ryza_chat_mvp/src/vertex_ai.dart';

const narrative = '旁白：夜色安静。\n莱莎：[calm][face:happy][action:none]今天也很不错。';
const rawReply =
    '<Interleaving><thinking>hidden fixture</thinking>$narrative'
    '</Interleaving><disclaimer>footer fixture</disclaimer>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('bundled source is byte-identical to the supplied preset', () async {
    final bytes = await rootBundle.load(keminiPresetAsset);
    final digest = await Sha256().hash(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    expect(
      digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      '3d394088a2b4c19a6d819a9cfba7bfacb372296a626c1192eaa6cab62c383968',
    );
    final preset = await KeminiPreset.load();
    expect(preset.sourceDocument['prompts'], hasLength(55));
    expect(preset.sourceOrder, hasLength(50));
    expect(
      preset.sourceOrder.where((e) => e['enabled'] == true),
      hasLength(30),
    );
  });

  test('only explicit roleplay exclusions change; one adapter inserted without reordering', () async {
    final preset = await KeminiPreset.load();
    final source = preset.sourceDocument;
    final original = jsonEncode(source);
    final effective = preset.effectiveDocument('PERFORMANCE');
    final prompts = effective['prompts'] as List;
    expect(prompts.length, 56);
    for (final p in source['prompts'] as List) {
      final expected = Map<String, dynamic>.from(p as Map);
      if (p['identifier'] == keminiDisclaimerId) expected['enabled'] = true;
      if (keminiDisabledIds.contains(p['identifier'])) {
        expected['enabled'] = false;
      }
      final prefixes = keminiSuppressedLinePrefixes[p['identifier']];
      if (prefixes != null) {
        expected['content'] = (expected['content'] as String)
            .split('\n')
            .where((line) => !prefixes.any(line.startsWith))
            .join('\n');
      }
      expect(
        prompts.firstWhere((x) => x['identifier'] == p['identifier']),
        expected,
        reason:
            'Every original field, including content and role, must survive',
      );
    }
    final order = (effective['prompt_order'] as List).single['order'] as List;
    final filtered = order
        .where((p) => p['identifier'] != nativePerformanceId)
        .toList();
    final expectedOrder = preset.sourceOrder;
    expectedOrder.firstWhere(
      (e) => e['identifier'] == keminiDisclaimerId,
    )['enabled'] = true;
    for (final e in expectedOrder) {
      if (keminiDisabledIds.contains(e['identifier'])) e['enabled'] = false;
    }
    expect(filtered, expectedOrder);
    final insertion = order.indexWhere(
      (e) => e['identifier'] == nativePerformanceId,
    );
    expect(order[insertion + 1]['identifier'], 'jailbreak');
    expect(
      (effective['prompt_order'] as List).single['character_id'],
      (source['prompt_order'] as List).single['character_id'],
    );
    for (final key in source.keys.where(
      (k) =>
          k != 'prompts' &&
          k != 'prompt_order' &&
          k != 'extensions' &&
          k != 'show_thoughts',
    )) {
      expect(effective[key], source[key]);
    }
    expect(jsonEncode(preset.sourceDocument), original);
    expect(effective['show_thoughts'], false);
    expect(keminiDisabledIds, {
      keminiLongExampleId,
      'main',
      'enhanceDefinitions',
    });
    final ext = effective['extensions'] as Map;
    expect(
      (ext['tavern_helper']['scripts'] as List).every(
        (s) => s['enabled'] == false,
      ),
      true,
    );
    for (final list in [
      ext['regex_scripts'],
      ext['SPreset']['RegexBinding']['regexes'],
    ]) {
      expect((list as List).every((r) => r['disabled'] == true), true);
    }
    final guide =
        prompts.firstWhere(
              (p) => p['identifier'] == 'd07b0943-0502-41b7-b126-a15998d4eca0',
            )['content']
            as String;
    expect(guide, isNot(contains('由DEEPMIND开发')));
    expect(guide, isNot(contains('当前为模型内测阶段')));
    expect(guide, isNot(contains('# 确保你Dramatron的身份')));
    expect(guide, contains('<writing_techniques>'));
    expect(guide, contains('{{getvar::writingstyle}}'));
  });

  test('compiler evaluates original macro order and fills markers at their positions', () async {
    final c = await AppController.load();
    addTearDown(c.dispose);
    c.setCharacterPersona('PERSONA {{setvar::rule::UNTRUSTED}}');
    c.setWorldSetting('WORLD');
    final plan = c.buildCharacterPromptPlan(currentInput: 'hi');
    expect(plan.executionOrder, hasLength(29));
    expect(
      plan.executionOrder,
      isNot(contains('d8a177f6-c0da-4ec1-824e-768a34d47d73')),
    );
    final messages = plan.assemble(
      agentSystemPrompt: 'HOST_TOOLS',
      history: [
        {'role': 'user', 'content': 'old user'},
        {'role': 'assistant', 'content': 'old assistant'},
        {'role': 'user', 'content': 'new user'},
      ],
    );
    int index(String id) => messages.indexWhere((m) => m['_presetId'] == id);
    expect(
      index('agentSystemPrompt'),
      lessThan(index('d07b0943-0502-41b7-b126-a15998d4eca0')),
    );
    expect(index('worldInfoBefore'), lessThan(index('charDescription')));
    expect(index('charDescription'), lessThan(index('chatHistory')));
    expect(
      messages[index('charDescription')]['content'],
      contains('PERSONA {{setvar::rule::UNTRUSTED}}'),
    );
    expect(
      index('chatHistory'),
      lessThan(index('93d5e5ab-c598-4780-b21b-fcc5cb071f94')),
    );
    expect(index('enhanceDefinitions'), -1);
    expect(index('main'), -1);
    expect(index(keminiLongExampleId), -1);
    final history = messages
        .where((m) => m['_presetId'] == 'chatHistory')
        .toList();
    expect(history.map((m) => m['role']), ['user', 'assistant', 'user']);
    expect(history.first['content'], 'old user');
    expect(
      history.last['content'],
      '<interactive_input>\nnew user\n</interactive_input>',
    );
    final writing =
        messages[index('d07b0943-0502-41b7-b126-a15998d4eca0')]['content']
            as String;
    expect(writing, contains('使用日式视觉小说风格'));
    expect(writing, isNot(contains('getvar::')));
    expect(writing, isNot(contains('UNTRUSTED')));
    expect(
      messages[index('451043ae-17bf-4162-a45f-2f80eb42ba67')]['content'],
      contains('第三人称'),
    );
    expect(
      messages[index('fd9adcfd-bbbe-447e-8be6-4f1d87e50da7')]['content'],
      contains('{{思考内容}}'),
    );
    expect(
      messages.any(
        (m) => m['_presetId'] == '0322500e-ee0e-4afb-ba06-2228307b74c5',
      ),
      false,
    );
    expect(
      messages[index(keminiDisclaimerId)]['content'],
      (c.keminiPreset.sourceDocument['prompts'] as List).firstWhere(
        (p) => p['identifier'] == keminiDisclaimerId,
      )['content'],
    );
    expect(messages[index('jailbreak')]['content'], endsWith('<Interleaving>'));
  });

  test(
    'entry switches, roles and macro edits are executed, not hardcoded',
    () async {
      final source = (await KeminiPreset.load()).sourceDocument;
      final order = (source['prompt_order'] as List).single['order'] as List;
      const style = 'f67b3638-2808-4cc0-a167-4f8ecc464e30';
      order.firstWhere((p) => p['identifier'] == style)['enabled'] = false;
      final p = (source['prompts'] as List).firstWhere(
        (p) => p['identifier'] == '7855d8d5-4c7a-4157-9284-d9b30c13ccfa',
      ) as Map;
      p['content'] = '{{setvar::rule::CUSTOM_RULE}}';
      final c = await AppController.load();
      addTearDown(c.dispose);
      final base = c.buildCharacterPromptPlan();
      final plan = KeminiPromptPlan(
        preset: KeminiPreset.fromJson(jsonEncode(source)),
        performanceProtocol: base.performanceProtocol,
        markers: base.markers,
        userName: 'USER',
      );
      expect(plan.executionOrder, isNot(contains(style)));
      final request = plan.assemble(history: const []);
      final writing =
          request.firstWhere(
                (m) => m['_presetId'] == 'd07b0943-0502-41b7-b126-a15998d4eca0',
              )['content']
              as String;
      expect(writing, contains('CUSTOM_RULE'));
      expect(writing, isNot(contains('使用日式视觉小说风格')));
    },
  );

  test('metadata parser handles every split, repeated blocks, and later story', () async {
    const raw =
        '<Interleaving><thinking>hidden1</thinking>$narrative'
        '<thinking>hidden2</thinking>\n旁白：夜更深了。</Interleaving><disclaimer>hidden3</disclaimer>';
    const expected = '$narrative\n旁白：夜更深了。';
    for (var split = 0; split <= raw.length; split++) {
      expect(
        await withoutKeminiMetadata(
          Stream.fromIterable([raw.substring(0, split), raw.substring(split)]),
        ).join(),
        expected,
      );
    }
    expect(
      await withoutKeminiMetadata(Stream.fromIterable(raw.split(''))).join(),
      expected,
    );
    expect(
      await withoutKeminiMetadata(
        Stream.value('$narrative<thinking>unfinished'),
      ).join(),
      narrative,
    );
    expect(
      await withoutKeminiMetadata(Stream.value('$narrative<thi')).join(),
      narrative,
    );
    expect(
      await withoutKeminiMetadata(
        Stream.value('<think>a<thinking>b</thinking>c</think>$narrative'),
      ).join(),
      narrative,
    );
    Stream<String> failing() async* {
      yield '<thinking>metadata';
      throw StateError('connection lost');
    }

    await expectLater(
      withoutKeminiMetadata(failing()).join(),
      throwsStateError,
    );
  });

  for (final provider in LlmProvider.values) {
    test(
      '$provider sends the complete ordered preset through the public chat route',
      () async {
        final c = await AppController.load();
        addTearDown(c.dispose);
        final plan = c.buildCharacterPromptPlan();
        final canonical = plan.assemble(
          agentSystemPrompt: 'HOST_TOOLS',
          history: [
            {'role': 'user', 'content': 'HISTORY_SENTINEL'},
          ],
        );
        var sends = 0;
        final httpClient = MockClient((request) async {
          sends++;
          final body = jsonDecode(request.body) as Map;
          List<String> wire;
          if (provider == LlmProvider.openAiCompatible) {
            final messages = body['messages'] as List;
            expect(messages.length, canonical.length);
            expect(
              messages.map((m) => m['role']),
              canonical.map((m) => m['role']),
            );
            expect(messages.any((m) => m.containsKey('_presetId')), false);
            wire = messages.map((m) => m['content'] as String).toList();
          } else if (provider == LlmProvider.vertexAi) {
            expect(
              body['systemInstruction']['parts'][0]['text'],
              orderedPresetTransportInstruction,
            );
            final contents = body['contents'] as List;
            expect(contents.length, canonical.length);
            wire = contents
                .map((m) => m['parts'][0]['text'] as String)
                .toList();
            for (var i = 0; i < contents.length; i++) {
              expect(
                contents[i]['role'],
                canonical[i]['role'] == 'assistant' ? 'model' : 'user',
              );
            }
          } else {
            expect(
              body['system_instruction'],
              orderedPresetTransportInstruction,
            );
            final input = body['input'] as List;
            expect(input.length, canonical.length);
            wire = input.map((m) => m['content'][0]['text'] as String).toList();
            for (var i = 0; i < input.length; i++) {
              expect(
                input[i]['type'],
                canonical[i]['role'] == 'assistant'
                    ? 'model_output'
                    : 'user_input',
              );
            }
          }
          for (var i = 0; i < canonical.length; i++) {
            // Host safety/tool marker is populated by the client, not this fixture.
            // Include it in the same position when comparing below.
            if (canonical[i]['_presetId'] == 'agentSystemPrompt') {
              expect(wire[i], contains('安全边界'));
            } else {
              expect(wire[i], contains(canonical[i]['content'] as String));
            }
          }
          if (provider == LlmProvider.vertexAi) {
            return http.Response(
              'data: ${jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'role': 'model',
                      'parts': [
                        {'text': rawReply},
                      ],
                    },
                    'finishReason': 'STOP',
                  },
                ],
              })}\n\n',
              200,
              headers: {'content-type': 'text/event-stream; charset=utf-8'},
            );
          }
          if (provider == LlmProvider.gemini) {
            return http.Response(
              jsonEncode({
                'status': 'completed',
                'steps': [
                  {
                    'type': 'model_output',
                    'content': [
                      {'type': 'text', 'text': rawReply},
                    ],
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': rawReply},
                },
              ],
            })}\n\ndata: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream; charset=utf-8'},
          );
        });
        final client = OpenAiCompatibleClient(
          client: httpClient,
          vertexClient: VertexAiClient(
            client: httpClient,
            tokenLoader: (_) async => auth.AccessToken(
              'Bearer',
              'test-token',
              DateTime.now().toUtc().add(const Duration(hours: 1)),
            ),
          ),
        );
        final answer = await client
            .streamChat(
              provider: provider,
              baseUrl: provider == LlmProvider.vertexAi
                  ? const VertexAiConfig(projectId: 'test-project').baseUrl
                  : 'https://example.test/v1',
              apiKey: 'test',
              model: 'gemini-2.5-flash',
              systemPrompt: '',
              promptPlan: plan,
              messages: const [
                ChatMessage(text: 'HISTORY_SENTINEL', isUser: true),
              ],
            )
            .join();
        expect(answer, narrative);
        expect(sends, 1);
      },
    );
  }
}
