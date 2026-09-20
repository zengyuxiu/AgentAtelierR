import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/kemini_disclaimer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const body = '旁白：夜色安静。\n莱莎：[calm][face:neutral][action:none]我在这里。\n';
  const footer = '<disclaimer>\n[SESSION_INTERRUPT_CHECK: OK]\n</disclaimer>';

  test(
    'footer hidden at every streaming boundary including truncated opening',
    () async {
      const raw = '$body$footer';
      for (var split = 0; split <= raw.length; split++) {
        expect(
          await withoutKeminiDisclaimer(
            Stream.fromIterable([
              raw.substring(0, split),
              raw.substring(split),
            ]),
          ).join(),
          body,
        );
      }
      expect(
        await withoutKeminiDisclaimer(Stream.fromIterable(raw.split('')))
            .join(),
        body,
      );
      expect(
        await withoutKeminiDisclaimer(Stream.value('$body<disclai')).join(),
        body,
      );
      expect(
        await withoutKeminiDisclaimer(Stream.value('$body<DISCLAIMER>hidden'))
            .join(),
        body,
      );
      expect(await withoutKeminiDisclaimer(Stream.value(body)).join(), body);
      expect(
        await withoutKeminiDisclaimer(Stream.value('正文 <普通文本>')).join(),
        '正文 <普通文本>',
      );
    },
  );

  test('upstream errors after footer are still propagated', () async {
    Stream<String> source() async* {
      yield '$body$footer';
      throw StateError('stream interrupted');
    }

    await expectLater(
      withoutKeminiDisclaimer(source()).join(),
      throwsStateError,
    );
  });

  test(
    'preset footer enabled in full and compact character prompts only',
    () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await AppController.load();
      addTearDown(controller.dispose);
      for (final compact in [false, true]) {
        controller.setLlmContextCompatibility(compact);
        final prompt = controller.buildCharacterPrompt();
        expect(prompt, contains(keminiDisclaimerId));
        expect(
          prompt,
          contains(
            (controller.keminiPreset.sourceDocument['prompts'] as List)
                    .firstWhere(
                      (p) => p['identifier'] == keminiDisclaimerId,
                    )['content']
                as String,
          ),
        );
        expect(prompt, contains('不带台词前缀'));
      }
      expect(
        controller.buildUserReplySuggestionPrompt(),
        isNot(contains(keminiDisclaimerId)),
      );
    },
  );

  test('public chat route injects footer instruction but exposes only story', () async {
    const keminiDisclaimerPrompt = '正文后生成隐藏的 <disclaimer> 尾段。';
    final client = OpenAiCompatibleClient(
      client: MockClient((request) async {
        final data = jsonDecode(request.body) as Map;
        expect(
          data['messages'][0]['content'],
          contains(keminiDisclaimerPrompt),
        );
        String event(String content) =>
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': content},
                },
              ],
            })}\n\n';
        return http.Response(
          '${event(body)}${event('<discl')}${event('aimer>hidden</disclaimer>')}data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream; charset=utf-8'},
        );
      }),
    );
    expect(
      await client
          .streamChat(
            baseUrl: 'https://example.test/v1',
            apiKey: 'test',
            model: 'test',
            systemPrompt: '$keminiDisclaimerId\n$keminiDisclaimerPrompt',
            messages: const [ChatMessage(text: 'hi', isUser: true)],
          )
          .join(),
      body,
    );
  });
}
