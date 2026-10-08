#ifndef RUNNER_SCREEN_ANNOTATOR_H_
#define RUNNER_SCREEN_ANNOTATOR_H_

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Teacher-style drawing while the assistant explains, in two places:
//
// - On the screen: circles, boxes, highlights, underlines, arrows, sketches
//   and notes over what the user is looking at, in 0..1000 coordinates of
//   the virtual desktop (the space of the screenshots the model sees).
//   Marks naming their target words land on those words, found by OCR;
//   other boxes are snapped to the content actually on screen. Marks keep a fixed
//   stacking order: highlights at the bottom, then shapes, arrows and notes,
//   then the whiteboard, with a floating app window always above them all.
//   Each mark is its own click-through window, excluded from capture.
//
// - On a whiteboard window, for explanations that start from scratch or
//   need room. Its coordinates are 0..1000 across its canvas; everything on
//   it is drawn on one surface. It can be dragged by its title bar. It stays
//   until the user closes it (or a new board replaces its page): when the
//   assistant moves back to the screen, the board just stops taking marks.
//
// Marks are drawn one after another at a hand's pace; notes are written
// glyph by glyph in bundled handwriting fonts with natural irregularities.
//
// For practice, the whiteboard also takes the student's handwriting: with an
// "exercise" command it shows Submit and Clear buttons, strokes made with
// the mouse or a pen become ink, and Submit posts a JPEG of the board to the
// app window as kBoardSubmitted.
class ScreenAnnotator {
 public:
  // Posted to the app window with a heap-allocated std::vector<uint8_t>.
  static constexpr UINT kBoardSubmitted = WM_APP + 75;

  struct Command {
    std::string type;  // circle, box, highlight, underline, line, arrow,
                       // text, path, whiteboard, close_whiteboard, clear,
                       // exercise
    std::vector<double> numbers;  // x1,y1,x2,y2 or x,y (0..1000)
    std::vector<std::pair<double, double>> points;  // path points (x, y)
    std::wstring text;  // note text, the whiteboard's title, or for an
                        // exercise its two button labels, one per line
    // The words on screen a mark is about. When given, the mark is placed
    // on where they really are, found by OCR near the model's aim.
    std::wstring target;
    // The box is an element's own box (a control or a text line the model
    // picked by id), so it is used as it is, not snapped.
    bool exact = false;
    std::string color;
    std::string size;  // s, m, l
  };

  // [app] is the assistant's own window, kept above the marks when it floats.
  explicit ScreenAnnotator(HWND app);
  ~ScreenAnnotator();
  void Draw(Command command);
  // Removes the screen marks; with [board], the whiteboard too.
  void Clear(bool board);

 private:
  struct Mark;
  struct Fonts;
  struct Board;
  void Run();
  void Apply(const Command& command, double now);
  std::unique_ptr<Mark> Build(const Command& command, bool on_board);
  void Paint(void* graphics, const Mark& mark, double now, double opacity);
  void Render(Mark& mark, double now);
  void RenderBoard(double now);
  size_t Stack(Mark& mark);
  void KeepOnTop();
  void Destroy(Mark& mark);
  void OpenBoard(const std::wstring& title, double now);
  void DestroyBoard();
  void StartExercise(const std::wstring& labels, double now);
  bool SnapshotBoard(std::vector<uint8_t>* jpeg);
  static void PaintInk(void* graphics, const Board& board, double opacity);
  RECT Snap(const std::string& type, RECT seed) const;
  static LRESULT CALLBACK BoardProc(HWND window, UINT message, WPARAM wparam,
                                    LPARAM lparam);

  HWND app_;
  std::thread thread_;
  HANDLE wake_ = nullptr;
  std::atomic<bool> quit_{false};
  std::mutex mutex_;
  std::deque<Command> pending_;
  // Screen marks, bottom to top in stacking order.
  std::vector<std::unique_ptr<Mark>> marks_;
  std::unique_ptr<Board> board_;
  std::unique_ptr<Fonts> fonts_;
  ULONG_PTR gdiplus_ = 0;
  // When the last scheduled mark finishes drawing.
  double queue_end_ = 0;
  uint32_t serial_ = 0;
};

#endif  // RUNNER_SCREEN_ANNOTATOR_H_
