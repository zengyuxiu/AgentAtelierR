import 'dart:io';

import 'package:ryza_chat_mvp/src/vertex_ai.dart';

/// Usage: dart run tool/verify_vertex_ai.dart /path/to/service-account.json [model] [location]
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/verify_vertex_ai.dart <json-path> [model] [location]',
    );
    exitCode = 64;
    return;
  }
  final client = VertexAiClient();
  try {
    final json = await File(args[0]).readAsString();
    final account = VertexServiceAccount.parse(json);
    final config = VertexAiConfig(
      projectId: account.projectId,
      location: args.length > 2 ? args[2] : 'global',
    );
    final model = args.length > 1 ? args[1] : 'gemini-2.5-flash';
    await client.accessToken(json);
    stdout.writeln('OAuth authentication: OK');
    for (final stream in [false, true]) {
      final output = await client
          .chat(
            baseUrl: config.baseUrl,
            credentialJson: json,
            model: model,
            stream: stream,
            messages: [
              {'role': 'user', 'content': 'Reply with only OK.'},
            ],
            generationConfig: {
              'maxOutputTokens': 128,
              if (model.startsWith('gemini-2.5-flash'))
                'thinkingConfig': {'thinkingBudget': 0},
            },
          )
          .join();
      stdout.writeln(
        '${stream ? 'Streaming' : 'GenerateContent'}: OK (${output.length} characters)',
      );
    }
    var toolCalls = 0;
    await client
        .chat(
          baseUrl: config.baseUrl,
          credentialJson: json,
          model: model,
          messages: [
            {
              'role': 'user',
              'content':
                  'Call connection_probe once, then reply with its result.',
            },
          ],
          tools: [
            {
              'function': {
                'name': 'connection_probe',
                'description': 'Return the connection check result.',
                'parameters': {
                  'type': 'object',
                  'properties': <String, dynamic>{},
                  'additionalProperties': false,
                },
              },
            },
          ],
          executeTool: (_) async {
            toolCalls++;
            return 'OK';
          },
          generationConfig: {
            'maxOutputTokens': 256,
            if (model.startsWith('gemini-2.5-flash'))
              'thinkingConfig': {'thinkingBudget': 0},
          },
        )
        .drain<void>();
    if (toolCalls != 1) {
      throw const VertexAiException('Tool round-trip verification failed.');
    }
    stdout.writeln('Tool round-trip: OK');
    stdout.writeln(
      'Project: ${account.projectId}; location: ${config.location}; model: $model',
    );
  } on VertexAiException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } catch (_) {
    stderr.writeln(
      'Verification failed; check credential file access and network.',
    );
    exitCode = 1;
  } finally {
    client.close();
  }
}
