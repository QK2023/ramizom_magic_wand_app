#include "screen_controls.h"

#include <dwmapi.h>
#include <uiautomation.h>
#include <wrl/client.h>

#include <algorithm>
#include <set>
#include <utility>

using Microsoft::WRL::ComPtr;

namespace screen_controls {
namespace {

// Total controls listed, and per window: enough for any task, while the
// list stays short enough to send with every annotated turn.
constexpr size_t kMaxControls = 150;
constexpr size_t kMaxPerWindow = 110;

const char* KindOf(CONTROLTYPEID type) {
  switch (type) {
    case UIA_ButtonControlTypeId:
      return "button";
    case UIA_SplitButtonControlTypeId:
      return "split";
    case UIA_MenuItemControlTypeId:
      return "menu";
    case UIA_TabItemControlTypeId:
      return "tab";
    case UIA_HyperlinkControlTypeId:
      return "link";
    case UIA_CheckBoxControlTypeId:
      return "check";
    case UIA_RadioButtonControlTypeId:
      return "radio";
    case UIA_ComboBoxControlTypeId:
      return "combo";
    case UIA_EditControlTypeId:
      return "edit";
    case UIA_ListItemControlTypeId:
    case UIA_DataItemControlTypeId:
      return "item";
    case UIA_TreeItemControlTypeId:
      return "tree";
    default:
      return nullptr;  // text is read by OCR; panes and groups say nothing
  }
}

bool Cloaked(HWND window) {
  DWORD cloaked = 0;
  return SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                         sizeof(cloaked))) &&
         cloaked != 0;
}

// The windows the user is looking at: the frontmost few app windows that
// are not this app's own, plus the taskbar.
std::vector<HWND> FrontWindows() {
  struct Search {
    std::vector<HWND> found;
    DWORD self;
  } search{{}, GetCurrentProcessId()};
  EnumWindows(
      [](HWND window, LPARAM data) -> BOOL {
        auto& search = *reinterpret_cast<Search*>(data);
        if (search.found.size() >= 2) return FALSE;
        DWORD process = 0;
        GetWindowThreadProcessId(window, &process);
        if (process == search.self || !IsWindowVisible(window) ||
            IsIconic(window) || Cloaked(window)) {
          return TRUE;
        }
        const LONG_PTR style = GetWindowLongPtr(window, GWL_EXSTYLE);
        if (style & WS_EX_TOOLWINDOW) return TRUE;
        RECT rect;
        if (!GetWindowRect(window, &rect)) return TRUE;
        const LONG w = rect.right - rect.left, h = rect.bottom - rect.top;
        if (w < 200 || h < 120) return TRUE;
        wchar_t name[64] = {};
        GetClassNameW(window, name, 64);
        if (wcscmp(name, L"Progman") == 0 || wcscmp(name, L"WorkerW") == 0 ||
            wcscmp(name, L"Shell_TrayWnd") == 0) {
          return TRUE;
        }
        search.found.push_back(window);
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&search));
  if (HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr)) {
    search.found.push_back(taskbar);
  }
  return search.found;
}

}  // namespace

std::vector<Control> ReadControls() {
  std::vector<Control> controls;
  ComPtr<IUIAutomation> automation;
  if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&automation))) &&
      FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&automation)))) {
    return controls;
  }
  // An app that does not answer must not hold up the request.
  ComPtr<IUIAutomation2> timed;
  if (SUCCEEDED(automation.As(&timed))) {
    timed->put_ConnectionTimeout(1500);
    timed->put_TransactionTimeout(1200);
  }

  ComPtr<IUIAutomationCacheRequest> cache;
  ComPtr<IUIAutomationCondition> control, visible, both;
  VARIANT yes;
  yes.vt = VT_BOOL;
  yes.boolVal = VARIANT_TRUE;
  VARIANT no;
  no.vt = VT_BOOL;
  no.boolVal = VARIANT_FALSE;
  if (FAILED(automation->CreateCacheRequest(&cache)) ||
      FAILED(automation->CreatePropertyCondition(UIA_IsControlElementPropertyId,
                                                 yes, &control)) ||
      FAILED(automation->CreatePropertyCondition(UIA_IsOffscreenPropertyId, no,
                                                 &visible)) ||
      FAILED(automation->CreateAndCondition(control.Get(), visible.Get(),
                                            &both))) {
    return controls;
  }
  cache->AddProperty(UIA_NamePropertyId);
  cache->AddProperty(UIA_ControlTypePropertyId);
  cache->AddProperty(UIA_BoundingRectanglePropertyId);
  cache->put_AutomationElementMode(AutomationElementMode_None);

  std::set<std::pair<std::wstring, LONG>> seen;
  for (HWND window : FrontWindows()) {
    if (controls.size() >= kMaxControls) break;
    RECT bounds;
    GetWindowRect(window, &bounds);
    ComPtr<IUIAutomationElement> root;
    ComPtr<IUIAutomationElementArray> found;
    if (FAILED(automation->ElementFromHandle(window, &root)) || !root ||
        FAILED(root->FindAllBuildCache(TreeScope_Descendants, both.Get(),
                                       cache.Get(), &found)) ||
        !found) {
      continue;
    }
    int count = 0;
    found->get_Length(&count);
    size_t taken = 0;
    for (int i = 0; i < count && taken < kMaxPerWindow &&
                    controls.size() < kMaxControls;
         ++i) {
      ComPtr<IUIAutomationElement> element;
      if (FAILED(found->GetElement(i, &element)) || !element) continue;
      CONTROLTYPEID type = 0;
      element->get_CachedControlType(&type);
      const char* kind = KindOf(type);
      if (!kind) continue;
      BSTR name = nullptr;
      element->get_CachedName(&name);
      std::wstring text = name ? std::wstring(name, SysStringLen(name)) : L"";
      SysFreeString(name);
      // One line, trimmed; long names are labels of whole panes.
      std::replace_if(text.begin(), text.end(),
                      [](wchar_t c) { return c == L'\n' || c == L'\r' || c == L'\t'; },
                      L' ');
      while (!text.empty() && text.back() == L' ') text.pop_back();
      while (!text.empty() && text.front() == L' ') text.erase(0, 1);
      if (text.empty() || text.size() > 60) continue;
      RECT rect{};
      if (FAILED(element->get_CachedBoundingRectangle(&rect))) continue;
      RECT inside;
      if (rect.right - rect.left < 4 || rect.bottom - rect.top < 4 ||
          !IntersectRect(&inside, &rect, &bounds)) {
        continue;
      }
      if (!seen.insert({text, rect.left * 100000 + rect.top}).second) continue;
      controls.push_back({inside, std::move(text), kind});
      ++taken;
    }
  }
  return controls;
}

}  // namespace screen_controls
