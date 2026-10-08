/// Turns a Markdown reply into what a person would say aloud: structure
/// becomes pauses and words, formulas are read as mathematics in Chinese or
/// English, and markup symbols are never pronounced.
library;

import 'annotation_service.dart';

/// Whether [text] reads as Chinese (decides the wording for formulas).
bool looksChinese(String text) => RegExp(r'[㐀-鿿]').hasMatch(text);

/// Spoken form of a Markdown fragment.
String speakable(String markdown, {required bool chinese}) {
  // Drawing commands are performed, not read.
  var text = AnnotationService.strip(markdown);

  // Code blocks are shown, not read.
  text = text.replaceAllMapped(
    RegExp(r'```[^\n`]*\n?[\s\S]*?(```|$)'),
    (_) => chinese ? '这里有一段代码，请在屏幕上查看。' : "There's a code snippet on screen. ",
  );

  // Formulas, display and inline.
  String math(Match m) => ' ${speakMath(m[1]!, chinese: chinese)} ';
  text = text
      .replaceAllMapped(RegExp(r'\$\$([\s\S]+?)\$\$'), math)
      .replaceAllMapped(RegExp(r'\\\[([\s\S]+?)\\\]'), math)
      .replaceAllMapped(RegExp(r'\\\(([\s\S]+?)\\\)'), math)
      .replaceAllMapped(
        RegExp(r'(?<![\\\w])\$(?=\S)([^$\n]*?\S)\$(?!\d)'),
        math,
      );

  final lines = <String>[];
  for (var line in text.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    // Table separator rows and horizontal rules carry nothing to say.
    if (RegExp(r'^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$').hasMatch(line) ||
        RegExp(r'^([-*_]\s*){3,}$').hasMatch(line)) {
      continue;
    }
    // Table rows: cells read one after another.
    if (line.startsWith('|') && line.endsWith('|') && line.length > 1) {
      final cells = line
          .substring(1, line.length - 1)
          .split('|')
          .map((cell) => cell.trim())
          .where((cell) => cell.isNotEmpty);
      line = '${cells.join(chinese ? '，' : ', ')}${chinese ? '。' : '. '}';
    }
    // Headings end in a pause.
    final heading = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
    if (heading != null) {
      line =
          '${heading[1]}${_endsSentence(heading[1]!) ? '' : (chinese ? '。' : '.')}';
    }
    line = line.replaceFirst(RegExp(r'^>\s?'), '');
    // Numbered items: "第一，" / "First, ".
    final numbered = RegExp(r'^(\d{1,2})[.)]\s+(.*)$').firstMatch(line);
    if (numbered != null) {
      line = '${_ordinal(int.parse(numbered[1]!), chinese)}${numbered[2]}';
    }
    // Bullets: just the item.
    line = line.replaceFirst(RegExp(r'^[-*+]\s+(\[[ xX]\]\s+)?'), '');
    lines.add(line);
  }
  // Each line is its own thought: pause between lines.
  text = [
    for (var i = 0; i < lines.length; i++)
      i < lines.length - 1 && !_endsClause(lines[i])
          ? '${lines[i]}${chinese ? '。' : '.'}'
          : lines[i],
  ].join(chinese ? '' : ' ');

  text = text
      // Images and links keep their words; bare addresses become "a link".
      .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAll(RegExp(r'(https?://|www\.)\S+'), chinese ? '一个链接' : 'a link')
      // Inline code is read as its contents.
      .replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m[1]!)
      // Emphasis and strike-through markers.
      .replaceAllMapped(RegExp(r'(\*\*|__|~~)(.+?)\1'), (m) => m[2]!)
      .replaceAllMapped(
        RegExp(r'(?<![\w*])[*_]([^*_\n]+?)[*_](?![\w*])'),
        (m) => m[1]!,
      )
      .replaceAll(RegExp(r'<[^>]+>'), '');

  text = _speakSymbols(text, chinese: chinese)
      .replaceAll(
        RegExp(
          r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]',
          unicode: true,
        ),
        '',
      )
      .replaceAll(RegExp(r'[#*_`~|>]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r' (?=[。，！？；：])'), '')
      .trim();
  // Decimals are read the Chinese way: the point as 点 and every digit after
  // it on its own, so "3.20" is 三点二零, never 三二十 or a time of day;
  // "1.2.3" is 一点二点三.
  if (chinese) {
    const digits = '零一二三四五六七八九';
    text = text.replaceAllMapped(
      RegExp(r'(?<=\d)\.(\d+)'),
      (m) => '点${m[1]!.split('').map((d) => digits[int.parse(d)]).join()}',
    );
  }
  return text;
}

bool _endsClause(String text) =>
    RegExp(r'[。！？.!?：:，,；;]$').hasMatch(text.trim());

bool _endsSentence(String text) => RegExp(r'[。！？.!?：:]$').hasMatch(text.trim());

String _ordinal(int n, bool chinese) {
  if (chinese) {
    const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
    final word = n <= 10
        ? digits[n]
        : n < 20
        ? '十${digits[n - 10]}'
        : '$n';
    return '第$word，';
  }
  const words = [
    'Zero', 'First', 'Second', 'Third', 'Fourth', 'Fifth', //
    'Sixth', 'Seventh', 'Eighth', 'Ninth', 'Tenth',
  ];
  return n <= 10 ? '${words[n]}, ' : 'Number $n, ';
}

/// Symbols in ordinary prose.
String _speakSymbols(String text, {required bool chinese}) {
  text = text.replaceAllMapped(
    RegExp(r'(\d+(?:\.\d+)?)\s*%'),
    (m) => chinese ? '百分之${m[1]}' : '${m[1]} percent',
  );
  text = text.replaceAllMapped(
    RegExp(r'(\d+(?:\.\d+)?)\s*°C'),
    (m) => chinese ? '${m[1]}摄氏度' : '${m[1]} degrees Celsius',
  );
  text = text.replaceAllMapped(
    RegExp(r'(\d+(?:\.\d+)?)\s*°'),
    (m) => chinese ? '${m[1]}度' : '${m[1]} degrees',
  );
  text = text
      .replaceAll(' < ', chinese ? ' 小于 ' : ' is less than ')
      .replaceAll(' > ', chinese ? ' 大于 ' : ' is greater than ')
      .replaceAll(' = ', chinese ? ' 等于 ' : ' equals ');
  final words = chinese ? _zhSymbols : _enSymbols;
  for (final entry in words.entries) {
    text = text.replaceAll(entry.key, ' ${entry.value} ');
  }
  return text;
}

const _zhSymbols = {
  '≥': '大于等于', '≤': '小于等于', '≠': '不等于', '≈': '约等于', //
  '±': '正负', '×': '乘以', '÷': '除以', '√': '根号', 'π': '派',
  '∞': '无穷', '→': '到', '⇒': '推出', '∈': '属于', '∑': '求和',
  '∫': '积分', '∆': '德尔塔', 'Δ': '德尔塔', 'α': '阿尔法', 'β': '贝塔',
  'θ': '西塔', 'λ': '兰姆达', 'μ': '缪', 'σ': '西格玛', 'Ω': '欧米伽',
};

const _enSymbols = {
  '≥': 'at least', '≤': 'at most', '≠': 'is not equal to', //
  '≈': 'is approximately', '±': 'plus or minus', '×': 'times',
  '÷': 'divided by', '√': 'the square root of', 'π': 'pi',
  '∞': 'infinity', '→': 'to', '⇒': 'implies', '∈': 'in', '∑': 'the sum of',
  '∫': 'the integral of', '∆': 'delta', 'Δ': 'delta', 'α': 'alpha',
  'β': 'beta', 'θ': 'theta', 'λ': 'lambda', 'μ': 'mu', 'σ': 'sigma',
  'Ω': 'omega',
};

/// Reads a LaTeX formula as words, e.g. `\frac{-b \pm \sqrt{b^2-4ac}}{2a}`
/// becomes "2a 分之负 b 正负根号 b 的平方减 4ac".
String speakMath(String latex, {required bool chinese}) {
  final parser = _MathReader(latex, chinese);
  return parser.read().replaceAll(RegExp(r'\s+'), ' ').trim();
}

class _MathReader {
  _MathReader(this.source, this.chinese);
  final String source;
  final bool chinese;
  int index = 0;

  String w(String zh, String en) => chinese ? zh : en;

  String read() => _sequence(null);

  bool get _done => index >= source.length;
  String get _peek => _done ? '' : source[index];

  void _skipSpaces() {
    while (!_done && source[index].trim().isEmpty) {
      index++;
    }
  }

  String _sequence(String? until) {
    final parts = <String>[];
    while (true) {
      _skipSpaces();
      if (_done || (until != null && _peek == until)) break;
      // A minus with nothing before it, or after an operator, is a sign.
      if (_peek == '-' && (parts.isEmpty || _operators.contains(parts.last))) {
        index++;
        final value = _atom() ?? '';
        parts.add(_scripts('${w('负', 'negative')} $value'));
        continue;
      }
      final atom = _atom();
      if (atom == null) continue;
      parts.add(_scripts(atom));
    }
    if (until != null && _peek == until) index++;
    return parts.where((p) => p.trim().isNotEmpty).join(' ');
  }

  /// One argument: a {group} or a single atom.
  String _argument() {
    _skipSpaces();
    if (_peek == '{') {
      index++;
      return _sequence('}');
    }
    return _atom() ?? '';
  }

  String _command() {
    final start = index;
    if (!_done && RegExp(r'[A-Za-z]').hasMatch(_peek)) {
      while (!_done && RegExp(r'[A-Za-z]').hasMatch(_peek)) {
        index++;
      }
    } else if (!_done) {
      index++;
    }
    return source.substring(start, index);
  }

  /// Reads `_x^y` after a big operator such as \sum.
  ({String? lower, String? upper}) _limits() {
    String? lower, upper;
    for (var i = 0; i < 2; i++) {
      _skipSpaces();
      if (_peek == '_') {
        index++;
        lower = _argument();
      } else if (_peek == '^') {
        index++;
        upper = _argument();
      }
    }
    return (lower: lower, upper: upper);
  }

  String? _atom() {
    final c = _peek;
    index++;
    switch (c) {
      case '{':
        return _sequence('}');
      case '}':
        return null;
      case '\\':
        return _macro(_command());
      case '+':
        return w('加', 'plus');
      case '-':
        return w('减', 'minus');
      case '=':
        return w('等于', 'equals');
      case '<':
        return w('小于', 'is less than');
      case '>':
        return w('大于', 'is greater than');
      case '*':
        return w('乘', 'times');
      case '/':
        return w('除以', 'divided by');
      case ',':
        return w('，', ',');
      case '!':
        return w('的阶乘', 'factorial');
      case "'":
        return w('导', 'prime');
      case '(' || ')' || '[' || ']' || '|' || '&' || '~':
        return ' ';
      case '^' || '_':
        // A script with nothing before it.
        return _argument();
    }
    // Runs of digits stay together ("123", "3.14").
    if (RegExp(r'[0-9.]').hasMatch(c)) {
      final start = index - 1;
      while (!_done && RegExp(r'[0-9.]').hasMatch(_peek)) {
        index++;
      }
      return source.substring(start, index);
    }
    return _symbol(c);
  }

  String _symbol(String c) {
    final words = chinese ? _zhSymbols : _enSymbols;
    return words[c] ?? c;
  }

  /// Applies superscripts and subscripts that follow [base].
  String _scripts(String base) {
    var result = base;
    while (true) {
      _skipSpaces();
      if (_peek == '^') {
        index++;
        final power = _argument().trim();
        result = '$result ${_power(power)}';
      } else if (_peek == '_') {
        index++;
        final sub = _argument().trim();
        result = '$result ${w('下标', 'sub')} $sub';
      } else {
        return result;
      }
    }
  }

  String _power(String power) => switch (power) {
    '2' => w('的平方', 'squared'),
    '3' => w('的立方', 'cubed'),
    '' => '',
    // x^\circ is an angle, not a power.
    _ when power == w('度', 'degrees') => w('度', 'degrees'),
    _ => w('的 $power 次方', 'to the power of $power'),
  };

  String? _macro(String name) {
    switch (name) {
      case 'frac' || 'dfrac' || 'tfrac' || 'cfrac':
        final top = _argument();
        final bottom = _argument();
        return w('$bottom 分之 $top', '$top over $bottom');
      case 'sqrt':
        _skipSpaces();
        String? degree;
        if (_peek == '[') {
          index++;
          degree = _sequence(']');
        }
        final body = _argument();
        if (degree == null || degree == '2') {
          return w('根号 $body', 'the square root of $body');
        }
        return w('$body 的 $degree 次方根', 'the root $degree of $body');
      case 'sum' || 'prod' || 'int' || 'oint' || 'lim':
        final limits = _limits();
        final lower = limits.lower, upper = limits.upper;
        if (name == 'lim') {
          return lower == null
              ? w('极限', 'the limit of')
              : w('当 $lower 时的极限，', 'the limit as $lower of');
        }
        final verb = switch (name) {
          'sum' => w('求和', 'the sum'),
          'prod' => w('连乘', 'the product'),
          _ => w('积分', 'the integral'),
        };
        if (lower == null && upper == null) {
          return chinese ? '$verb，' : '$verb of';
        }
        return chinese
            ? '从 ${lower ?? ''} 到 ${upper ?? ''} $verb，'
            : '$verb from ${lower ?? ''} to ${upper ?? ''} of';
      case 'text' ||
          'mathrm' ||
          'textbf' ||
          'mathbf' ||
          'mathit' ||
          'operatorname' ||
          'mathcal' ||
          'mathbb' ||
          'boldsymbol' ||
          'textrm' ||
          'mbox':
        return _argument();
      case 'left' ||
          'right' ||
          'big' ||
          'Big' ||
          'bigg' ||
          'Bigg' ||
          'displaystyle' ||
          'limits' ||
          ',' ||
          ';' ||
          ':' ||
          '!' ||
          'quad' ||
          'qquad' ||
          ' ':
        return ' ';
      case '\\':
        return w('，', ',');
      case '{' || '}':
        return ' ';
      case '%':
        return w('百分号', 'percent');
      case 'overline' || 'bar':
        return w('${_argument()} 拔', '${_argument()} bar');
      case 'hat':
        return w('${_argument()} 帽', '${_argument()} hat');
      case 'vec':
        return w('向量 ${_argument()}', 'vector ${_argument()}');
      case 'begin' || 'end':
        _argument();
        return ' ';
    }
    final word = (chinese ? _zhMacros : _enMacros)[name];
    if (word != null) return word;
    return name;
  }
}

const _zhMacros = {
  'pm': '正负', 'mp': '负正', 'times': '乘以', 'cdot': '乘', 'div': '除以', //
  'neq': '不等于', 'ne': '不等于', 'leq': '小于等于', 'le': '小于等于',
  'geq': '大于等于', 'ge': '大于等于', 'approx': '约等于', 'equiv': '恒等于',
  'sim': '相似于', 'propto': '正比于', 'infty': '无穷', 'to': '趋近于',
  'rightarrow': '趋近于', 'Rightarrow': '推出', 'implies': '推出',
  'Leftrightarrow': '当且仅当', 'iff': '当且仅当', 'in': '属于',
  'notin': '不属于', 'subset': '包含于', 'subseteq': '包含于', 'cup': '并',
  'cap': '交', 'forall': '对任意', 'exists': '存在', 'partial': '偏',
  'nabla': '梯度', 'cdots': '等等', 'ldots': '等等', 'dots': '等等',
  'angle': '角', 'circ': '度', 'degree': '度', 'perp': '垂直于',
  'parallel': '平行于', 'sin': 'sin', 'cos': 'cos', 'tan': 'tan',
  'log': 'log', 'ln': 'ln', 'exp': 'e 的指数', 'max': '最大值', 'min': '最小值',
  'alpha': '阿尔法', 'beta': '贝塔', 'gamma': '伽马', 'Gamma': '伽马',
  'delta': '德尔塔', 'Delta': '德尔塔', 'epsilon': '艾普西隆',
  'varepsilon': '艾普西隆', 'zeta': '泽塔', 'eta': '伊塔', 'theta': '西塔',
  'Theta': '西塔', 'lambda': '兰姆达', 'Lambda': '兰姆达', 'mu': '缪',
  'nu': '纽', 'xi': '克西', 'pi': '派', 'Pi': '派', 'rho': '柔',
  'sigma': '西格玛', 'Sigma': '西格玛', 'tau': '陶', 'phi': '斐',
  'varphi': '斐', 'Phi': '斐', 'chi': '卡', 'psi': '普西', 'Psi': '普西',
  'omega': '欧米伽', 'Omega': '欧米伽',
};

const _enMacros = {
  'pm': 'plus or minus', 'mp': 'minus or plus', 'times': 'times', //
  'cdot': 'times', 'div': 'divided by', 'neq': 'is not equal to',
  'ne': 'is not equal to', 'leq': 'is at most', 'le': 'is at most',
  'geq': 'is at least', 'ge': 'is at least', 'approx': 'is approximately',
  'equiv': 'is equivalent to', 'sim': 'is similar to',
  'propto': 'is proportional to', 'infty': 'infinity', 'to': 'approaches',
  'rightarrow': 'approaches', 'Rightarrow': 'implies', 'implies': 'implies',
  'Leftrightarrow': 'if and only if', 'iff': 'if and only if', 'in': 'in',
  'notin': 'not in', 'subset': 'subset of', 'subseteq': 'subset of',
  'cup': 'union', 'cap': 'intersect', 'forall': 'for all',
  'exists': 'there exists', 'partial': 'partial', 'nabla': 'nabla',
  'cdots': 'and so on', 'ldots': 'and so on', 'dots': 'and so on',
  'angle': 'angle', 'circ': 'degrees', 'degree': 'degrees',
  'perp': 'perpendicular to', 'parallel': 'parallel to', 'sin': 'sine',
  'cos': 'cosine', 'tan': 'tangent', 'log': 'log', 'ln': 'natural log of',
  'exp': 'exp', 'max': 'max', 'min': 'min', 'alpha': 'alpha',
  'beta': 'beta', 'gamma': 'gamma', 'Gamma': 'gamma', 'delta': 'delta',
  'Delta': 'delta', 'epsilon': 'epsilon', 'varepsilon': 'epsilon',
  'zeta': 'zeta', 'eta': 'eta', 'theta': 'theta', 'Theta': 'theta',
  'lambda': 'lambda', 'Lambda': 'lambda', 'mu': 'mu', 'nu': 'nu',
  'xi': 'xi', 'pi': 'pi', 'Pi': 'pi', 'rho': 'rho', 'sigma': 'sigma',
  'Sigma': 'sigma', 'tau': 'tau', 'phi': 'phi', 'varphi': 'phi',
  'Phi': 'phi', 'chi': 'chi', 'psi': 'psi', 'Psi': 'psi', 'omega': 'omega',
  'Omega': 'omega',
};

/// Words after which a minus sign means "negative".
const _operators = {
  '加', '减', '等于', '小于', '大于', '乘', '乘以', '除以', '正负', '负正', //
  '小于等于', '大于等于', '约等于', '不等于', '，', 'plus', 'minus', 'equals',
  'is less than', 'is greater than', 'times', 'divided by', 'plus or minus',
  'is at most', 'is at least', 'is approximately', 'is not equal to', ',',
};
