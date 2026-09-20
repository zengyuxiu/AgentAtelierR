/// Vertex/Interactions have a single system field, not interleaved system roles.
/// Only these ordered-preset requests use in-place system segments. Plain chat
/// keeps its existing transport. Never silently hoist the preset's late rules.
const orderedPresetTransportInstruction =
    '以下输入按原预设的执行顺序排列。以 <preset_system identifier="..."> '
    '包裹的段落是预设系统条目；其位置有意义，不能当作用户台词或故事历史。'
    '其他 user/model 内容保持各自角色。只输出预设要求的本轮回复；'
    '原生演出台本条目定义说话者、动画、语音的输出语法。';

Map<String, dynamic> orderedPresetWireMessage(Map<String, dynamic> message) {
  if (message['role'] != 'system') return Map.of(message);
  final identifier = message['_presetId'] as String? ?? 'system';
  return {
    'role': 'user',
    'content':
        '<preset_system identifier="$identifier">\n'
        '${message['content']}\n</preset_system>',
  };
}
