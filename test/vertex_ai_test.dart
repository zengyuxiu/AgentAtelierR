import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ryza_chat_mvp/src/ai_services.dart';
import 'package:ryza_chat_mvp/src/app_controller.dart';
import 'package:ryza_chat_mvp/src/model_thinking.dart';
import 'package:ryza_chat_mvp/src/vertex_ai.dart';
import 'package:ryza_chat_mvp/src/vertex_ai_settings.dart';

final base = const VertexAiConfig(projectId: 'test-project').baseUrl;
const messages = <Map<String, dynamic>>[
  {'role': 'user', 'content': 'hi'},
];
auth.AccessToken token(String value, [DateTime? expires]) => auth.AccessToken(
  'Bearer',
  value,
  expires ?? DateTime.now().toUtc().add(const Duration(hours: 1)),
);
Map<String, dynamic> result(
  List<Map<String, dynamic>> parts, {
  String? finish = 'STOP',
}) => {
  'candidates': [
    {
      'content': {'role': 'model', 'parts': parts},
      'finishReason': ?finish,
    },
  ],
};
final ok = result([
  {'text': 'OK'},
]);
Stream<String> request(
  VertexAiClient client, {
  bool stream = false,
  String json = 'test',
}) => client.chat(
  baseUrl: base,
  credentialJson: json,
  model: 'gemini-2.5-flash',
  messages: messages,
  stream: stream,
);

class StreamingVertexHttp extends http.BaseClient {
  StreamingVertexHttp(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

List<int> sse(Map<String, dynamic> event) =>
    utf8.encode('data: ${jsonEncode(event)}\n\n');

class MemorySecrets extends SecretStore {
  String saved = '';
  int writes = 0;
  @override
  Future<String> readVertexCredentials() async => saved;
  @override
  Future<void> writeVertexCredentials(String value) async {
    saved = value;
    writes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Agent text arrives before the HTTP response closes', () async {
    final wire = StreamController<List<int>>();
    final client = OpenAiCompatibleClient(
      vertexClient: VertexAiClient(
        tokenLoader: (_) async => token('token'),
        client: StreamingVertexHttp((request) async {
          expect(request.url.path, endsWith(':streamGenerateContent'));
          expect(request.url.query, 'alt=sse');
          final body = jsonDecode((request as http.Request).body) as Map;
          expect(body['tools'], isNotEmpty);
          return http.StreamedResponse(wire.stream, 200);
        }),
      ),
    );
    final iterator = StreamIterator(
      client.streamChat(
        baseUrl: base,
        apiKey: 'json',
        model: 'gemini-2.5-flash',
        provider: LlmProvider.vertexAi,
        systemPrompt: 'roleplay',
        agentEnabled: true,
        messages: const [ChatMessage(text: 'hi', isUser: true)],
      ),
    );
    addTearDown(iterator.cancel);
    wire.add(
      sse(
        result([
          {'text': '第一段'},
        ], finish: null),
      ),
    );
    expect(await iterator.moveNext().timeout(const Duration(seconds: 2)), true);
    expect(iterator.current, '第一段');
    // The tail is deliberately unavailable until the first visible delta arrives.
    wire.add(
      sse(
        result([
          {'text': '第二段'},
        ]),
      ),
    );
    unawaited(wire.close());
    expect(await iterator.moveNext(), true);
    expect(iterator.current, '第二段');
    expect(await iterator.moveNext(), false);
  });

  test(
    'streamed tool round preserves signatures and streams its final answer',
    () async {
      var requests = 0;
      var executions = 0;
      final toolPart = {
        'functionCall': {
          'name': 'lookup',
          'args': {'query': 'hi'},
          'id': 'call1',
        },
        'thoughtSignature': 'opaque',
      };
      final tail = StreamController<List<int>>();
      final client = VertexAiClient(
        tokenLoader: (_) async => token('token'),
        client: StreamingVertexHttp((request) async {
          expect(request.url.query, 'alt=sse');
          final body = jsonDecode((request as http.Request).body) as Map;
          if (++requests == 1) {
            return http.StreamedResponse(
              Stream.fromIterable([
                sse(result([toolPart], finish: null)),
                sse(result([])),
              ]),
              200,
            );
          }
          expect(body['contents'][1]['parts'], [toolPart]);
          expect(
            body['contents'][2]['parts'][0]['functionResponse']['id'],
            'call1',
          );
          return http.StreamedResponse(tail.stream, 200);
        }),
      );
      final iterator = StreamIterator(
        client.chat(
          baseUrl: base,
          credentialJson: 'json',
          model: 'gemini-2.5-flash',
          messages: messages,
          tools: [
            {
              'function': {
                'name': 'lookup',
                'parameters': {'type': 'object'},
              },
            },
          ],
          executeTool: (_) async {
            executions++;
            return 'found';
          },
        ),
      );
      addTearDown(iterator.cancel);
      tail.add(
        sse(
          result([
            {'text': '已找到'},
          ], finish: null),
        ),
      );
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 2)),
        true,
      );
      expect(iterator.current, '已找到');
      expect(executions, 1);
      tail.add(
        sse(
          result([
            {'text': '结果'},
          ]),
        ),
      );
      unawaited(tail.close());
      expect(await iterator.moveNext(), true);
      expect(iterator.current, '结果');
      expect(await iterator.moveNext(), false);
      expect(requests, 2);
    },
  );

  test('truncated streamed tool calls do not execute', () async {
    var executions = 0;
    final client = VertexAiClient(
      tokenLoader: (_) async => token('token'),
      client: StreamingVertexHttp(
        (_) async => http.StreamedResponse(
          Stream.value(
            sse(
              result([
                {
                  'functionCall': {'name': 'lookup', 'args': {}},
                },
              ], finish: null),
            ),
          ),
          200,
        ),
      ),
    );
    await expectLater(
      client
          .chat(
            baseUrl: base,
            credentialJson: 'json',
            model: 'gemini-2.5-flash',
            messages: messages,
            tools: [
              {
                'function': {
                  'name': 'lookup',
                  'parameters': {'type': 'object'},
                },
              },
            ],
            executeTool: (_) async {
              executions++;
              return 'found';
            },
          )
          .join(),
      throwsA(isA<VertexAiException>()),
    );
    expect(executions, 0);
  });

  test('service account uses secure provider storage and invalid replacement is rejected', () async {
    FlutterSecureStorage.setMockInitialValues({
      'vertex_service_account_json': 'credential-sentinel',
    });
    const secrets = SecretStore();
    expect(
      await secrets.readLlmKey(LlmProvider.vertexAi),
      'credential-sentinel',
    );
    await expectLater(
      secrets.writeVertexCredentials('{invalid secret}'),
      throwsA(isA<VertexAiException>()),
    );
    expect(await secrets.readVertexCredentials(), 'credential-sentinel');
    final controller = await AppController.load();
    expect(
      jsonEncode(controller.exportData()),
      isNot(contains('credential-sentinel')),
    );
    expect(
      (await SharedPreferences.getInstance()).getKeys(),
      isNot(contains('vertex_service_account_json')),
    );
    await secrets.writeVertexCredentials('');
    expect(await secrets.readVertexCredentials(), isEmpty);
    controller.dispose();
  });

  test('repeated 401 stops after one refresh', () async {
    var loads = 0;
    var sends = 0;
    final client = VertexAiClient(
      tokenLoader: (_) async => token('${++loads}'),
      client: MockClient((_) async {
        sends++;
        return http.Response('{}', 401);
      }),
    );
    await expectLater(
      request(client).join(),
      throwsA(isA<VertexAiException>()),
    );
    expect(loads, 2);
    expect(sends, 2);
  });

  test(
    'undeclared tools and more than ten calls execute no side effects',
    () async {
      for (final names in [
        List.filled(11, 'lookup'),
        ['lookup', 'unknown'],
      ]) {
        var executions = 0;
        final client = VertexAiClient(
          tokenLoader: (_) async => token('token'),
          client: MockClient(
            (_) async => http.Response(
              jsonEncode(
                result([
                  for (final name in names)
                    {
                      'functionCall': {'name': name, 'args': {}},
                    },
                ]),
              ),
              200,
            ),
          ),
        );
        await expectLater(
          client
              .chat(
                baseUrl: base,
                credentialJson: 'json',
                model: 'gemini-2.5-flash',
                messages: messages,
                stream: false,
                tools: [
                  {
                    'function': {
                      'name': 'lookup',
                      'parameters': {'type': 'object'},
                    },
                  },
                ],
                executeTool: (_) async {
                  executions++;
                  return 'result';
                },
              )
              .join(),
          throwsA(isA<VertexAiException>()),
        );
        expect(executions, 0);
      }
    },
  );

  test(
    'untrusted endpoint rejected before auth; regional and global paths',
    () async {
      expect(
        const VertexAiConfig(
          projectId: 'test-project',
          location: 'us-central1',
        ).baseUrl,
        'https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google',
      );
      var authCalls = 0;
      final client = VertexAiClient(
        tokenLoader: (_) async {
          authCalls++;
          return token('secret');
        },
      );
      addTearDown(client.close);
      for (final url in [
        '$base?key=oops',
        base.replaceFirst('googleapis.com', 'evil.test'),
        base.replaceFirst('https:', 'http:'),
        '$base/../openai',
      ]) {
        await expectLater(
          client
              .chat(
                baseUrl: url,
                credentialJson: 'key',
                model: 'gemini-2.5-flash',
                messages: messages,
              )
              .join(),
          throwsA(isA<VertexAiException>()),
        );
      }
      expect(authCalls, 0);
      expect(
        () => VertexServiceAccount.parse('{"private_key":"secret"}'),
        throwsA(
          isA<VertexAiException>().having(
            (e) => e.message,
            'redacted',
            isNot(contains('secret')),
          ),
        ),
      );
    },
  );

  test(
    'token cache coalesces refresh and isolates concurrent accounts',
    () async {
      var now = DateTime.utc(2026);
      var loads = 0;
      final client = VertexAiClient(
        now: () => now,
        tokenLoader: (json) async {
          loads++;
          await Future<void>.delayed(Duration.zero);
          return token(json, now.add(const Duration(minutes: 2)));
        },
      );
      addTearDown(client.close);
      expect(
        await Future.wait([client.accessToken('A'), client.accessToken('A')]),
        ['A', 'A'],
      );
      expect(loads, 1);
      await client.accessToken('A');
      expect(loads, 1);
      now = now.add(const Duration(seconds: 61));
      await client.accessToken('A');
      expect(loads, 2);
      expect(
        await Future.wait([client.accessToken('B'), client.accessToken('C')]),
        ['B', 'C'],
      );
      expect(await client.accessToken('C'), 'C');
      expect(loads, 4);
    },
  );

  test(
    '401 refresh once and never sends JSON as bearer; redirects disabled',
    () async {
      var loads = 0;
      var requests = 0;
      final client = VertexAiClient(
        tokenLoader: (_) async => token('token-${++loads}'),
        client: MockClient((req) async {
          expect(req.followRedirects, false);
          expect(req.headers['Authorization'], 'Bearer token-${++requests}');
          expect(req.body, isNot(contains('private_key')));
          return http.Response(
            requests == 1 ? '{}' : jsonEncode(ok),
            requests == 1 ? 401 : 200,
          );
        }),
      );
      expect(
        await request(client, json: '{"private_key":"never transmit"}').join(),
        'OK',
      );
      expect(loads, 2);
    },
  );

  test('ordinary and streaming routes include multimodal history and native thinking', () async {
    final client = OpenAiCompatibleClient(
      vertexClient: VertexAiClient(
        tokenLoader: (_) async => token('token'),
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map;
          expect(body.containsKey('messages'), false);
          expect(body.containsKey('input'), false);
          if (req.url.query == 'alt=sse') {
            expect(
              body['systemInstruction']['parts'][0]['text'],
              contains('system'),
            );
            expect(
              body['generationConfig']['thinkingConfig']['thinkingBudget'],
              0,
            );
            return http.Response(
              ': heartbeat\n\ndata: ${jsonEncode(result([
                {'thought': true, 'text': 'hidden'},
              ], finish: null))}\n\n'
              'data: ${jsonEncode(ok)}',
              200,
            );
          }
          expect(req.url.path.endsWith(':generateContent'), true);
          return http.Response(jsonEncode(ok), 200);
        }),
      ),
    );
    expect(
      await client.complete(
        baseUrl: base,
        apiKey: 'json',
        model: 'gemini-2.5-flash',
        provider: LlmProvider.vertexAi,
        messages: const [
          {'role': 'user', 'content': 'hi'},
        ],
      ),
      'OK',
    );
    expect(
      await client
          .streamChat(
            baseUrl: base,
            apiKey: 'json',
            model: 'gemini-2.5-flash',
            provider: LlmProvider.vertexAi,
            systemPrompt: 'system',
            thinkingEnabled: false,
            messages: const [ChatMessage(text: 'hi', isUser: true)],
          )
          .join(),
      'OK',
    );
  });

  test(
    'attachments map to inlineData; model role and system are separate',
    () async {
      final client = VertexAiClient(
        tokenLoader: (_) async => token('token'),
        client: MockClient((req) async {
          final body = jsonDecode(req.body) as Map;
          expect(body['contents'][0]['role'], 'model');
          expect(body['contents'][1]['parts'][0]['inlineData'], {
            'mimeType': 'image/png',
            'data': 'AQID',
          });
          expect(
            body['contents'][1]['parts'][1]['inlineData']['mimeType'],
            'application/pdf',
          );
          expect(body['systemInstruction']['parts'][0]['text'], 'sys');
          return http.Response(jsonEncode(ok), 200);
        }),
      );
      await client
          .chat(
            baseUrl: base,
            credentialJson: 'json',
            model: 'gemini-2.5-flash',
            stream: false,
            messages: [
              {'role': 'system', 'content': 'sys'},
              {'role': 'assistant', 'content': 'old'},
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'data:image/png;base64,AQID'},
                  },
                  {
                    'type': 'file',
                    'file': {'file_data': 'data:application/pdf;base64,AQID'},
                  },
                ],
              },
            ],
          )
          .drain<void>();
    },
  );

  test('tool response preserves thought signatures and only executes declared calls', () async {
    var requests = 0;
    var executions = 0;
    final toolPart = {
      'functionCall': {
        'name': 'lookup',
        'args': {'query': 'hi'},
        'id': 'call1',
      },
      'thoughtSignature': 'opaque-signature',
    };
    final client = VertexAiClient(
      tokenLoader: (_) async => token('token'),
      client: MockClient((req) async {
        final body = jsonDecode(req.body) as Map;
        expect(
          body['tools'][0]['functionDeclarations'][0]['parametersJsonSchema']['additionalProperties'],
          false,
        );
        if (++requests == 1) {
          return http.Response(jsonEncode(result([toolPart])), 200);
        }
        expect(body['contents'][1]['parts'][0], toolPart);
        expect(body['contents'][2]['parts'][0]['functionResponse'], {
          'name': 'lookup',
          'id': 'call1',
          'response': {'result': 'found'},
        });
        return http.Response(jsonEncode(ok), 200);
      }),
    );
    expect(
      await client
          .chat(
            baseUrl: base,
            credentialJson: 'json',
            model: 'gemini-2.5-flash',
            messages: messages,
            stream: false,
            tools: [
              {
                'function': {
                  'name': 'lookup',
                  'description': 'lookup',
                  'parameters': {
                    'type': 'object',
                    'additionalProperties': false,
                  },
                },
              },
            ],
            executeTool: (call) async {
              executions++;
              expect(jsonDecode(call['function']['arguments']), {
                'query': 'hi',
              });
              return 'found';
            },
          )
          .join(),
      'OK',
    );
    expect(executions, 1);
  });

  test(
    'truncated, blocked, HTTP error and malformed streams fail safely',
    () async {
      for (final response in [
        http.Response(
          'data: ${jsonEncode(result([
            {'text': 'partial'},
          ], finish: null))}\n\n',
          200,
        ),
        http.Response(
          'data: ${jsonEncode(result([], finish: 'SAFETY'))}\n\n',
          200,
        ),
        http.Response('data: malformed private_key\n\n', 200),
        http.Response('secret server payload', 403),
        http.Response('{}', 302),
      ]) {
        final client = VertexAiClient(
          tokenLoader: (_) async => token('token'),
          client: MockClient((_) async => response),
        );
        await expectLater(
          request(client, stream: true).join(),
          throwsA(
            isA<VertexAiException>().having(
              (e) => e.message,
              'safe message',
              isNot(contains('private_key')),
            ),
          ),
        );
      }
    },
  );

  test(
    'Vertex settings persist and backup has no service account credential',
    () async {
      final controller = await AppController.load();
      controller.configureVertexAi(
        enabled: true,
        projectId: 'test-project',
        location: 'global',
        model: 'gemini-2.5-flash',
      );
      final backup = controller.exportData();
      expect(jsonEncode(backup), isNot(contains('private_key')));
      await Future<void>.delayed(Duration.zero);
      final restored = await AppController.load();
      expect(restored.llmProvider, LlmProvider.vertexAi);
      expect(restored.activeLlmBaseUrl, base);
      await restored.importData(backup);
      expect(restored.llmProvider, LlmProvider.vertexAi);
      expect(restored.activeLlmBaseUrl, base);
      expect(restored.activeLlmModel, 'gemini-2.5-flash');
      expect(restored.modelThinking.canToggle, true);
      expect(
        identifyModelThinking(
          'gemini-2.5-pro',
          vertexNative: true,
        ).requestFields(enabled: false),
        {
          'generationConfig': {
            'thinkingConfig': {'thinkingBudget': -1},
          },
        },
      );
      controller.dispose();
      restored.dispose();
    },
  );

  testWidgets('small screen and large text layout; missing JSON cannot save', (
    tester,
  ) async {
    final controller = (await tester.runAsync(AppController.load))!;
    final secrets = MemorySecrets();
    addTearDown(controller.dispose);
    for (final size in [
      const Size(375, 812),
      const Size(812, 375),
      const Size(1024, 768),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: size.width == 812 ? ThemeData.light() : ThemeData.dark(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
              disableAnimations: true,
            ),
            child: VertexAiSettingsPage(
              controller: controller,
              secrets: secrets,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(secrets.writes, 0);
      expect(controller.llmProvider, LlmProvider.openAiCompatible);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
