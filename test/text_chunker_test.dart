import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_asr/core/text/text_chunker.dart';

/// Rebuilds the chunk boundaries a caller can rely on: no chunk exceeds the
/// budget, and concatenating them gives back the trimmed input.
void expectTiles(String text, {int maxTokens = 512}) {
  final chunks = chunkForEmbedding(text, maxTokens: maxTokens);
  expect(chunks.join(), text.trim(), reason: 'chunks must tile the input');
  for (final chunk in chunks) {
    expect(estimatedTokens(chunk), lessThanOrEqualTo(maxTokens));
    expect(chunk, isNotEmpty);
  }
}

void main() {
  test('estimatedTokens overestimates CJK at one token per character', () {
    expect(estimatedTokens(''), 0);
    expect(estimatedTokens('你好世界'), 4);
    expect(estimatedTokens('abc'), 1); // 3 * 0.3 rounds up
    expect(estimatedTokens('a' * 40), 12);
    expect(
      estimatedTokens('你好世界'),
      greaterThan(estimatedTokens('abcdefgh')),
      reason: 'CJK costs more per character',
    );
  });

  test('short text is a single untouched chunk', () {
    expect(chunkForEmbedding('今天下雨。'), ['今天下雨。']);
    expect(chunkForEmbedding('   '), isEmpty);
    expect(chunkForEmbedding(''), isEmpty);
  });

  test('paragraphs form their own chunks once the budget is reached', () {
    const one = '第一段讨论了整体计划和一个大概的方向。';
    const two = '第二段说明了人员分工以及重要的时间节点。';
    final chunks = chunkForEmbedding('$one\n$two', maxTokens: estimatedTokens(one) + 1);
    expect(chunks.length, 2);
    expect(chunks.first, '$one\n');
    expectTiles('$one\n$two', maxTokens: estimatedTokens(one) + 1);
  });

  test('a sentence longer than the budget is hard-cut', () {
    final sentence = '这是一句非常长的话没有标点' * 20;
    final chunks = chunkForEmbedding(sentence, maxTokens: 16);
    expect(chunks.length, greaterThan(1));
    expectTiles(sentence, maxTokens: 16);
  });

  test('an over-budget budget is rejected', () {
    expect(
      () => chunkForEmbedding('x', maxTokens: 0),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a long mixed transcript is bounded and lossless', () {
    const text =
        '会议开始，我们先确认上次的待办事项。\n'
        'First, the build pipeline was reviewed in detail. '
        'It looked fine. '
        '然后我们讨论了下个阶段的排期与风险。\n'
        '最后确定了负责人和验收标准！';
    for (final budget in [8, 16, 32, 512]) {
      final chunks = chunkForEmbedding(text * 12, maxTokens: budget);
      expect(chunks.length, greaterThan(1));
      expect(
        chunks.join(),
        (text * 12).trim(),
        reason: 'no character may be dropped at budget $budget',
      );
      for (final chunk in chunks) {
        expect(estimatedTokens(chunk), lessThanOrEqualTo(budget));
      }
    }
  });
}
