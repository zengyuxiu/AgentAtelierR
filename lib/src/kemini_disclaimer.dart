/// User-selected preset footer. Textual claims do not change provider policy
/// or token limits. The original preset file remains untouched.
const keminiDisclaimerId = '095b5c1f-cf5f-48e8-a6aa-e25c882ea754';

/// Native equivalent of the preset's metadata removal for visible/history text.
/// Keep the raw ordered prompt structure; hide only output metadata, not story.
Stream<String> withoutKeminiMetadata(Stream<String> source) async* {
  const names = [
    'think',
    'thinking',
    'disclaimer',
    'reference_example',
    'interleaving',
  ];
  final tokens = [
    for (final name in names) ...['<$name>', '</$name>'],
  ];
  final tag = RegExp(
    r'<(/?)(think|thinking|disclaimer|reference_example|interleaving)>',
    caseSensitive: false,
  );
  final hidden = <String>[];
  var pending = '';
  await for (final chunk in source) {
    pending += chunk;
    while (pending.isNotEmpty) {
      final match = tag.firstMatch(pending);
      if (match == null) {
        final lastStart = pending.lastIndexOf('<');
        final partial =
            lastStart >= 0 &&
            tokens.any(
              (t) => t.startsWith(pending.substring(lastStart).toLowerCase()),
            );
        final safeEnd = partial ? lastStart : pending.length;
        if (hidden.isEmpty && safeEnd > 0) yield pending.substring(0, safeEnd);
        pending = pending.substring(safeEnd);
        break;
      }
      if (hidden.isEmpty && match.start > 0) {
        yield pending.substring(0, match.start);
      }
      final name = match.group(2)!.toLowerCase();
      if (name != 'interleaving') {
        if (match.group(1) == '') {
          hidden.add(name);
        } else if (hidden.contains(name)) {
          hidden.removeRange(hidden.lastIndexOf(name), hidden.length);
        }
      }
      pending = pending.substring(match.end);
    }
  }
  // Incomplete metadata stays hidden at EOF. Stream errors are never swallowed.
}

/// Drop the reserved footer before UI, TTS, animation and conversation history.
/// Buffer partial opening tags so network chunk boundaries cannot leak them.
/// Continue consuming the source after the footer, preserving transport errors.
Stream<String> withoutKeminiDisclaimer(Stream<String> source) async* {
  const opening = '<disclaimer>';
  var pending = '';
  var footerStarted = false;
  await for (final chunk in source) {
    if (footerStarted) continue;
    pending += chunk;
    final normalized = pending.toLowerCase();
    final index = normalized.indexOf(opening);
    if (index >= 0) {
      if (index > 0) yield pending.substring(0, index);
      pending = '';
      footerStarted = true;
      continue;
    }
    var suffixLength = 0;
    for (
      var length = 1;
      length < opening.length && length <= pending.length;
      length++
    ) {
      if (normalized.endsWith(opening.substring(0, length))) {
        suffixLength = length;
      }
    }
    final visibleLength = pending.length - suffixLength;
    if (visibleLength > 0) yield pending.substring(0, visibleLength);
    pending = pending.substring(visibleLength);
  }
  // An unfinished footer opening at EOF is metadata, not spoken dialogue.
}
