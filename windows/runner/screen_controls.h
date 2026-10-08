#ifndef RUNNER_SCREEN_CONTROLS_H_
#define RUNNER_SCREEN_CONTROLS_H_

#include <windows.h>

#include <string>
#include <vector>

// The controls the user can see and click: buttons, menu items, tabs,
// links, fields, list and tree items, read through UI Automation from the
// windows in front (and the taskbar). Unlike text found by OCR, these
// include icon-only buttons, by their accessible names, with exact boxes,
// so the assistant can point at them by id instead of guessing coordinates.
//
// Call on a thread in the multithreaded apartment. Rectangles are in
// physical screen pixels.
namespace screen_controls {

struct Control {
  RECT rect;
  std::wstring name;
  const char* kind;  // button, menu, tab, link, check, radio, combo, edit,
                     // item, tree, split
};

std::vector<Control> ReadControls();

}  // namespace screen_controls

#endif  // RUNNER_SCREEN_CONTROLS_H_
