#ifndef RUNNER_SCREEN_TEXT_H_
#define RUNNER_SCREEN_TEXT_H_

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

// Text on the screen, read with the Windows OCR engine, so annotations can
// land on the exact words a model means rather than where it guessed.
//
// - ReadDesktop() lists the text lines on every monitor with their boxes;
//   the model receives them with the screenshot and can copy coordinates
//   instead of estimating them from pixels.
// - Locate() finds the words a mark is about on the live screen, preferring
//   matches near where the model aimed, and tolerating OCR slips.
//
// All rectangles are in physical screen pixels.
namespace screen_text {

struct Word {
  RECT rect;
  std::wstring text;
};

struct Line {
  RECT rect;
  std::wstring text;
  std::vector<Word> words;
};

// Every text line on every monitor, top to bottom per monitor.
std::vector<Line> ReadDesktop();

// Where [target] appears on screen, near [seed] when it appears more than
// once. Nothing when the text cannot be found with confidence.
std::optional<RECT> Locate(const std::wstring& target, RECT seed);

}  // namespace screen_text

#endif  // RUNNER_SCREEN_TEXT_H_
