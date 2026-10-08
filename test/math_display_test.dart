import 'package:flutter_test/flutter_test.dart';
import 'package:ramizom_magic_wand/services/math_display.dart';
import 'package:ramizom_magic_wand/services/speakable_text.dart';

void main() {
  test('formulas are written as symbols', () {
    expect(mathDisplay(r'x^2 + 2x + 1'), 'x² + 2x + 1');
    expect(mathDisplay(r'\frac{a+b}{2}'), '(a+b)/2');
    expect(mathDisplay(r'\frac{1}{2}'), '1/2');
    expect(mathDisplay(r'\sqrt{b^2-4ac}'), '√(b²−4ac)');
    expect(
      mathDisplay(r'x = \frac{-b \pm \sqrt{b^2-4ac}}{2a}'),
      'x = (−b ± √(b²−4ac))/(2a)',
    );
    expect(
      mathDisplay(r'a_1 \leq b_{n+1}, \alpha \to \infty'),
      'a₁ ≤ bₙ₊₁, α → ∞',
    );
    expect(mathDisplay(r'\sum_{i=1}^{n} i'), '∑ᵢ₌₁ⁿ i');
    expect(mathDisplay(r'e^{i\pi} + 1 = 0'), 'e^(iπ) + 1 = 0');
    expect(mathDisplay(r'\sin\theta \cdot \cos\theta'), 'sinθ · cosθ');
    expect(mathDisplay(r'\left( x \right)'), '( x )');
  });

  test('captions keep formulas as symbols and drop drawing commands', () {
    expect(
      displayText(r'解得 $x^2=4$，所以 x 是 $\pm 2$。<draw>{"type":"clear"}</draw>'),
      '解得 x²=4，所以 x 是 ± 2。',
    );
    expect(displayText(r'价格是 $5 和 $6'), r'价格是 $5 和 $6');
    expect(displayText('hello <draw>{"type":"ci'), 'hello ');
  });

  test('decimals are read digit by digit after the point in Chinese', () {
    expect(
      speakable('版本是 9.2，价格 3.20 元。', chinese: true),
      '版本是 9点二，价格 3点二零 元。',
    );
    expect(speakable('增长了 12.05%', chinese: true), contains('12点零五'));
    expect(speakable('1.2.3 版', chinese: true), contains('1点二点三'));
    expect(speakable('Version 9.2 is out.', chinese: false), contains('9.2'));
    // Sentence ends and numbered lists keep their dots.
    expect(speakable('共有 3 个。然后是 4。', chinese: true), isNot(contains('点')));
    expect(speakable('1. 先做这个\n2. 再做那个', chinese: true), isNot(contains('点')));
  });
}
