import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/services/speakable_text.dart';
import 'package:ramizom_magic_wand/services/speech_service.dart';

void main() {
  test('formulas are read as mathematics in Chinese', () {
    expect(speakMath(r'A = \pi r^2', chinese: true), 'A 等于 派 r 的平方');
    expect(
      speakMath(r'x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}', chinese: true),
      'x 等于 2 a 分之 负 b 正负 根号 b 的平方 减 4 a c',
    );
    expect(speakMath(r'\sum_{i=1}^{n} i', chinese: true), '从 i 等于 1 到 n 求和， i');
    expect(speakMath(r'a \leq b', chinese: true), 'a 小于等于 b');
    expect(speakMath(r'90^\circ', chinese: true), '90 度');
  });

  test('formulas are read as mathematics in English', () {
    expect(speakMath(r'E = mc^2', chinese: false), 'E equals m c squared');
    expect(speakMath(r'\frac{1}{2}', chinese: false), '1 over 2');
    expect(speakMath(r'x^{10}', chinese: false), 'x to the power of 10');
  });

  test('markdown structure becomes natural speech, not symbols', () {
    expect(
      speakable(r'圆的面积是 $A = \pi r^2$。', chinese: true),
      '圆的面积是 A 等于 派 r 的平方。',
    );
    expect(speakable('## 结论', chinese: true), '结论。');
    expect(speakable('1. 准备材料\n2. 开始烹饪', chinese: true), '第一，准备材料。第二，开始烹饪');
    expect(
      speakable('**注意**：看[文档](https://x.y)，或访问 https://a.b', chinese: true),
      '注意：看文档，或访问 一个链接',
    );
    expect(
      speakable('```python\nprint(1)\n```', chinese: true),
      '这里有一段代码，请在屏幕上查看。',
    );
    expect(
      speakable('| 名称 | 价格 |\n| --- | --- |\n| 苹果 | 5 元 |', chinese: true),
      '名称，价格。苹果，5 元。',
    );
    expect(speakable('增长了 15%，约 30°C', chinese: true), '增长了 百分之15，约 30摄氏度');
    expect(
      speakable('Use `git status` first.', chinese: false),
      'Use git status first.',
    );
    expect(
      speakable('x ≥ 3 and y ≠ 0', chinese: false),
      'x at least 3 and y is not equal to 0',
    );
  });

  test('a piece never ends inside a formula, code block or list number', () {
    final buffer = StringBuffer(r'公式是 $a. b$ 吗？');
    final pieces = SpeechService.takePieces(buffer, first: false);
    expect(pieces.single.raw, r'公式是 $a. b$ 吗？');

    final code = StringBuffer('看这里：\n```dart\nfinal a = 1;\nprint(a);\n');
    final early = SpeechService.takePieces(code, first: false);
    // The open code block is held until it closes.
    expect(early.map((p) => p.raw).join(), '看这里：\n');
    code.write('```\n好了。');
    final rest = SpeechService.takePieces(code, first: false, flush: true);
    expect(rest.first.spoken, '这里有一段代码，请在屏幕上查看。');

    final list = StringBuffer('1. First step\n2. Second step\n');
    final items = SpeechService.takePieces(list, first: false, chinese: false);
    expect(items.map((p) => p.spoken), [
      'First, First step',
      'Second, Second step',
    ]);
  });
}
