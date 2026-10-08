import 'annotation_service.dart';

/// Reply text as it is shown in captions: drawing commands removed and
/// LaTeX formulas written the way people write them on paper — `x²+1`,
/// `(a+b)/2`, `√(b²−4ac)`, `≤`, `π` — instead of backslashes and braces.
/// What is spoken for the same text is `speakable`; the two differ on
/// purpose: formulas are heard as words but read as symbols.
String displayText(String text) {
  String math(Match m) => mathDisplay(m[1]!);
  return AnnotationService.strip(text)
      .replaceAllMapped(RegExp(r'\$\$([\s\S]+?)\$\$'), math)
      .replaceAllMapped(RegExp(r'\\\[([\s\S]+?)\\\]'), math)
      .replaceAllMapped(RegExp(r'\\\(([\s\S]+?)\\\)'), math)
      .replaceAllMapped(
        RegExp(r'(?<![\\\w])\$(?=\S)([^$\n]*?\S)\$(?!\d)'),
        math,
      );
}

/// A LaTeX formula in plain Unicode.
String mathDisplay(String latex) {
  var s = latex
      .replaceAll(RegExp(r'\\(left|right|big|Big|bigg|Bigg)(?![a-zA-Z])'), '')
      .replaceAll(RegExp(r'\\[,;:! ]|\\q?quad(?![a-zA-Z])'), ' ')
      .replaceAll(r'\\', ' ')
      .replaceAllMapped(
        RegExp(
          r'\\(?:text|mathrm|mathbf|mathit|mathbb|mathcal|operatorname|textbf|boldsymbol|bar|overline|hat|vec)\{([^{}]*)\}',
        ),
        (m) => m[1]!,
      );

  // Innermost groups first, until nothing is left to simplify.
  for (var round = 0; round < 12; round++) {
    final before = s;
    s = s
        .replaceAllMapped(
          RegExp(r'\\[dtc]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}'),
          (m) => '${_group(m[1]!)}/${_group(m[2]!)}',
        )
        .replaceAllMapped(
          RegExp(r'\\sqrt\s*\[([^\]]*)\]\s*\{([^{}]*)\}'),
          (m) =>
              '${_script(m[1]!, _superscripts) ?? '^(${m[1]})'}√${_group(m[2]!)}',
        )
        .replaceAllMapped(
          RegExp(r'\\sqrt\s*\{([^{}]*)\}'),
          (m) => '√${_group(m[1]!)}',
        )
        .replaceAllMapped(
          RegExp(r'\^\s*\{([^{}]*)\}'),
          (m) => _script(m[1]!, _superscripts) ?? '^(${m[1]})',
        )
        .replaceAllMapped(
          RegExp(r'_\s*\{([^{}]*)\}'),
          (m) => _script(m[1]!, _subscripts) ?? '_(${m[1]})',
        )
        .replaceAllMapped(
          RegExp(r'\^\s*([0-9a-zA-Z+\-])'),
          (m) => _script(m[1]!, _superscripts) ?? '^${m[1]}',
        )
        .replaceAllMapped(
          RegExp(r'_\s*([0-9a-zA-Z+\-])'),
          (m) => _script(m[1]!, _subscripts) ?? '_${m[1]}',
        );
    if (s == before) break;
  }

  s = s.replaceAllMapped(RegExp(r'\\([a-zA-Z]+)'), (m) {
    final name = m[1]!;
    return _symbols[name] ?? (_functions.contains(name) ? name : '');
  });
  s = s
      .replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!)
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll('-', '−')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return s;
}

/// [text] as a fraction part or radicand: bare when it is one term,
/// otherwise in parentheses.
String _group(String text) {
  final t = text.trim();
  // One number or one letter (with its exponent) stands alone; anything
  // else, like 2a or a+b, is bracketed so "/2a" can't be misread.
  final simple = RegExp(r'^(\d+(\.\d+)?|[^\W\d_])[²³⁴⁵⁶⁷⁸⁹⁰¹ⁿ]*$').hasMatch(t);
  return simple ? t : '($t)';
}

String? _script(String text, Map<String, String> table) {
  final t = text.replaceAll(' ', '');
  if (t.isEmpty) return '';
  final out = StringBuffer();
  for (final rune in t.runes) {
    final mapped = table[String.fromCharCode(rune)];
    if (mapped == null) return null;
    out.write(mapped);
  }
  return out.toString();
}

const _superscripts = {
  '0': '⁰',
  '1': '¹',
  '2': '²',
  '3': '³',
  '4': '⁴',
  '5': '⁵',
  '6': '⁶',
  '7': '⁷',
  '8': '⁸',
  '9': '⁹',
  '+': '⁺',
  '-': '⁻',
  '=': '⁼',
  '(': '⁽',
  ')': '⁾',
  'n': 'ⁿ',
  'i': 'ⁱ',
  'x': 'ˣ',
  'y': 'ʸ',
  'a': 'ᵃ',
  'b': 'ᵇ',
  'c': 'ᶜ',
  'd': 'ᵈ',
  'e': 'ᵉ',
  'k': 'ᵏ',
  'm': 'ᵐ',
  'p': 'ᵖ',
  't': 'ᵗ',
  'T': 'ᵀ',
  '∘': '°',
};

const _subscripts = {
  '0': '₀',
  '1': '₁',
  '2': '₂',
  '3': '₃',
  '4': '₄',
  '5': '₅',
  '6': '₆',
  '7': '₇',
  '8': '₈',
  '9': '₉',
  '+': '₊',
  '-': '₋',
  '=': '₌',
  '(': '₍',
  ')': '₎',
  'a': 'ₐ',
  'e': 'ₑ',
  'i': 'ᵢ',
  'j': 'ⱼ',
  'k': 'ₖ',
  'n': 'ₙ',
  'm': 'ₘ',
  'o': 'ₒ',
  'p': 'ₚ',
  'r': 'ᵣ',
  's': 'ₛ',
  't': 'ₜ',
  'x': 'ₓ',
  'u': 'ᵤ',
  'v': 'ᵥ',
  'h': 'ₕ',
  'l': 'ₗ',
};

const _functions = {
  'sin',
  'cos',
  'tan',
  'cot',
  'sec',
  'csc',
  'arcsin',
  'arccos',
  'arctan',
  'sinh',
  'cosh',
  'tanh',
  'log',
  'ln',
  'lg',
  'exp',
  'lim',
  'max',
  'min',
  'sup',
  'inf',
  'det',
  'gcd',
  'deg',
  'dim',
  'ker',
  'mod',
};

const _symbols = {
  // Operators and relations.
  'times': '×', 'cdot': '·', 'div': '÷', 'pm': '±', 'mp': '∓',
  'leq': '≤', 'le': '≤', 'geq': '≥', 'ge': '≥', 'neq': '≠', 'ne': '≠',
  'approx': '≈', 'equiv': '≡', 'sim': '∼', 'simeq': '≃', 'propto': '∝',
  'll': '≪', 'gg': '≫', 'cong': '≅',
  'to': '→', 'rightarrow': '→', 'leftarrow': '←', 'Rightarrow': '⇒',
  'Leftarrow': '⇐', 'leftrightarrow': '↔', 'Leftrightarrow': '⇔',
  'implies': '⇒', 'iff': '⇔', 'mapsto': '↦', 'uparrow': '↑',
  'downarrow': '↓',
  // Sets and logic.
  'in': '∈', 'notin': '∉', 'subset': '⊂', 'subseteq': '⊆', 'supset': '⊃',
  'supseteq': '⊇', 'cup': '∪', 'cap': '∩', 'emptyset': '∅',
  'varnothing': '∅', 'forall': '∀', 'exists': '∃', 'neg': '¬', 'land': '∧',
  'wedge': '∧', 'lor': '∨', 'vee': '∨', 'setminus': '∖',
  // Calculus and big operators.
  'sum': '∑', 'prod': '∏', 'int': '∫', 'iint': '∬', 'iiint': '∭',
  'oint': '∮', 'partial': '∂', 'nabla': '∇', 'infty': '∞', 'prime': '′',
  // Misc.
  'angle': '∠', 'perp': '⊥', 'parallel': '∥', 'triangle': '△',
  'circ': '∘', 'degree': '°', 'ldots': '…', 'cdots': '⋯', 'dots': '…',
  'vdots': '⋮', 'ddots': '⋱', 'therefore': '∴', 'because': '∵',
  'hbar': 'ℏ', 'ell': 'ℓ', 'Re': 'ℜ', 'Im': 'ℑ', 'aleph': 'ℵ',
  'lfloor': '⌊', 'rfloor': '⌋', 'lceil': '⌈', 'rceil': '⌉',
  'langle': '⟨', 'rangle': '⟩', 'lbrace': '{', 'rbrace': '}',
  'mid': '|', 'cdotp': '·', 'bullet': '•', 'star': '⋆', 'oplus': '⊕',
  'otimes': '⊗', 'dagger': '†',
  // Greek.
  'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ', 'epsilon': 'ε',
  'varepsilon': 'ε', 'zeta': 'ζ', 'eta': 'η', 'theta': 'θ',
  'vartheta': 'ϑ', 'iota': 'ι', 'kappa': 'κ', 'lambda': 'λ', 'mu': 'μ',
  'nu': 'ν', 'xi': 'ξ', 'pi': 'π', 'varpi': 'ϖ', 'rho': 'ρ',
  'varrho': 'ϱ', 'sigma': 'σ', 'varsigma': 'ς', 'tau': 'τ', 'upsilon': 'υ',
  'phi': 'φ', 'varphi': 'φ', 'chi': 'χ', 'psi': 'ψ', 'omega': 'ω',
  'Gamma': 'Γ', 'Delta': 'Δ', 'Theta': 'Θ', 'Lambda': 'Λ', 'Xi': 'Ξ',
  'Pi': 'Π', 'Sigma': 'Σ', 'Upsilon': 'Υ', 'Phi': 'Φ', 'Psi': 'Ψ',
  'Omega': 'Ω',
};
