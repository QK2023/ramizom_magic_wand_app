# Feature details

Detailed behaviour of Ramizom Magic Wand. For setup, see the [README](../README.md).

## What is included

- A conversation-first desktop layout: compact dated threads in the sidebar, a centered composer for new chats, an inline model picker and an optional screen-context panel. No projects, terminal, directory browser or model-executed device tools.
- English and Chinese (中文) throughout navigation, settings, history and shortcuts. Language and theme choices persist; a language saved by an earlier version (Traditional Chinese, Spanish, French) moves to Chinese or English.
- Local conversation history with full-text search, resume, pin, rename, delete and Markdown export.
- Streaming OpenAI-compatible responses, stop generation, retry, copy and read aloud.
- Rendered Markdown: headings, lists, tables, selectable text, highlighted code with copy controls, inline/display LaTeX. AI-provided remote images are opened only on user click.
- File picker, removable attachment chips, image/text preview, and file content included in model requests. Files are copied into the local workspace so resumed conversations retain their context.
- A prompt library for screen explanation, summarization, translation and writing; insert, edit and save prompt templates as ordinary user messages.
- Windows native screen capture with a visible preview, on-demand sharing, and the app window excluded from captures on supported Windows versions. While sharing, a flowing light in the app icon's colours runs around every monitor edge; it is click-through and excluded from captures, so the model never sees it.
- On-device speech recognition (SenseVoice with Silero VAD: Chinese, English, Cantonese, Japanese, Korean) with automatic conversational turns, and replies read aloud in Microsoft Edge neural voices (sixteen to choose from, including dialects and multilingual voices) with captions following the voice.
- Light, dark and system appearance modes with six persistent theme colors, including a neutral graphite default. The first launch is in Chinese on a Chinese Windows display language and in English otherwise.
- Purposeful motion: the composer glides from the welcome view to the bottom on the first message, replies stream with a thinking indicator and caret, a soft aurora glow surrounds the composer while the model replies or listens, and dialogs open over a blurred backdrop. Animations respect the system "reduce motion" setting.
- DeepSeek with a built-in model menu and four thinking depths, or any OpenAI-compatible custom API, whose `/models` list can be searched (image capability read from model metadata where given) or a model ID entered.

Shortcuts are reusable prompts, not a third-party executable plugin or MCP runtime. There are no inactive navigation placeholders.

## Screen annotations

While the screen is shared (and Settings → AI connection → Screen annotations is on), the assistant can teach visually. It is told not to draw unasked: when a visual walk-through would clearly help, it offers, and draws once the user agrees (or asks directly). It chooses between two places:

- **On the screen**, when the conversation is about what is on it: circles, boxes, highlights, underlines, arrows, sketches and short notes over the actual content.
- **On a whiteboard window**, when explaining from scratch, when the idea needs a diagram, formula or worked steps, or when the screen has no room. The whiteboard opens beside the assistant's window on the monitor in use and can be dragged by its title bar. It stays open until you close it (or the assistant starts a new board, which replaces the page): when the assistant moves back to the screen it only stops drawing on the board, and the automatic clean slate at the start of a reply clears screen marks but not the board.

Drawings are `<draw>{json}</draw>` commands placed right before the words they illustrate. While annotations are possible, the screenshot sent to the model carries a faint 0–1000 grid (the preview never shows it) and comes with a numbered list of **screen elements**: the clickable controls of the windows in front and the taskbar, read through UI Automation (`windows/runner/screen_controls.cpp`; buttons, menu items, tabs, links, fields, list and tree items, including icon-only buttons by their accessible names), and the text lines read by the Windows OCR engine (`windows/runner/screen_text.cpp`), at most 150 together, one compact line each (`12 button 412,88,460,110 Save`). The model points at an element by id (`{"type":"circle","ref":12}`, `{"type":"arrow","ref":12}`), optionally narrowing a text line to its exact words with `target`; the mark is then drawn on that element's own box, with no coordinates to guess. Coordinates (0–1000, x first) are only used for things not listed. Commands never appear as text — the chat, captions and voice strip them, and earlier replies are sent back to the model without them. When the reply is read aloud, each drawing appears as its words are spoken; otherwise drawings are spaced by the reading time of the text before them. Marks are drawn one after another at a hand's pace.

On screen, every mark settles on what is really there. A mark on an element is drawn on its box. A mark with a `target` is placed on those words as OCR finds them on the live screen: first around where the model aimed (enlarged 2× so small text reads well), then anywhere on that monitor, choosing the closest occurrence and tolerating OCR slips such as `0`/`O` or `1`/`l`; arrows with a `target` stop just short of their words. Marks without one fall back to pixel snapping: highlights and underlines find the exact text line and the words the target touches, circles and boxes tighten to the content they enclose, and the model's box is kept whenever the screen gives no clear answer. Screen marks keep a fixed stacking order — highlights at the bottom, then shapes, arrows and notes, then the whiteboard — and a floating mini window stays above them all. Each screen mark is its own click-through window; everything on the whiteboard is drawn on one surface. Notes use bundled handwriting fonts (Long Cang for Chinese, Caveat for Latin, both OFL, in `assets/fonts`) with per-glyph irregularities, falling back per character for symbols. Marks and the whiteboard are excluded from screen capture, so later screenshots show the user's real content. Clear everything from the "On-screen notes" chip in the composer, the button in the mini window, or by stopping screen sharing.

## Walkthroughs, practice and review

**Step-by-step walkthroughs.** Ask how to do something in an app on the shared screen and the assistant coaches you through it one step at a time: it says what to do, points at the exact control on your screen (found by OCR from its `target`), and ends the step with a hidden `<await>what the screen will show when done</await>`. The app then watches the screen locally every two seconds through a 96 × 60 grayscale fingerprint (a few milliseconds per look, blind to a clock ticking). Once the screen has changed and stayed the same for one more look, a plain screenshot is taken and a quick no-thinking request without system instructions asks the model whether the step is done, went wrong, or is still in progress. Done or wrong becomes a small note in the chat ("✓ Step 1 done") and the next step or a correction, spoken and drawn as usual; "still in progress" stays silent. A bar above the composer shows the step with **I'm done**, **Skip** and **End walkthrough**; the mini window has an **I'm done** button. Guiding ends when the task is finished, the screen is no longer shared, or the conversation changes (`lib/services/guide_service.dart`).

**Practice on the whiteboard.** After writing a question on the whiteboard, the assistant can send `{"type":"exercise"}`. The board then shows **Hand in** and **Clear** in its title bar and takes handwriting from the mouse or a pen. **Hand in** sends a JPEG of the board canvas (question, marks and answer, in the board's 0–1000 coordinates) as an `[Answer]` turn instead of a screenshot. The assistant marks it on the board like a teacher, with ticks, red circles and short corrections beside the wrong step, and lets you try again rather than giving the full solution.

**Learning notes and review.** When you leave a conversation in which you learned something (or three minutes after its last reply), a background request notes down up to five points worth remembering: topic, the point, a recall question with its answer, and the mistake you made, if any. They are stored in `workspace/learning.json`. Notes come up for review on a spaced schedule (1, 2, 4, 7, 15 and 30 days; a wrong answer starts over the next day). When something is due, the welcome screen shows **N to review today**. **Start review** opens a short quiz in a conversation of its own, typed or spoken, where the assistant asks one question at a time and marks each answer with a hidden `<review id result/>` tag that reschedules it. **Learning notes** lists everything with its mistakes and next review date, and entries can be deleted. Turn it off under Settings → General.

## Files and model context

Supported attachments: PNG, JPEG, WebP, PDF, UTF-8 text, Markdown, CSV, JSON, YAML, logs and common source-code extensions.

- Up to 4 files per message.
- Up to 10 MB per file; text/code files up to 200 KB.
- Images require a vision model.
- PDFs use [OpenRouter's file input format](https://openrouter.ai/docs/guides/overview/multimodal/pdfs), so they can be sent only to a custom API at `openrouter.ai`. PDF parsing/vision capabilities and costs depend on the selected model.
- Binary Office files and scanned-document local OCR are not included.
- Model context contains the recent 24 messages; previous screen snapshots are not retained. Text attachments are always resent. Earlier images and PDFs are resent newest-first within an 8 MB budget, and older ones become a short note so long visual conversations stay bounded. History files the current model cannot read (images for a text-only model, PDFs outside OpenRouter) are also replaced by a note instead of blocking the message.
- Markdown and math rendering use [gpt_markdown](https://pub.dev/packages/gpt_markdown).

## Local data

API keys use `flutter_secure_storage`. Preferences hold language, theme and connection metadata. Conversations, shortcuts and copied attachments live under the application's support directory in `workspace/`. Conversation files are serialized and backed up; they are local JSON, not encrypted archives. Attachment copies that no saved message references (for example from a draft discarded when the app closed) are removed on the next launch.

Screen frames are captured and JPEG-encoded off the window thread, so input stays responsive, and they stay in memory. Stopping sharing clears the preview. Screen images are transmitted to the configured AI service only with a message while sharing is active. File attachments are sent with their conversation context. Voice input is recognized and replies are spoken on-device, so no audio or reply text leaves the computer for speech. App-owned temporary playback audio is cleaned up on normal disposal.

## Keyboard shortcuts

- Enter: send; Shift+Enter: newline (IME composition is respected).
- Ctrl+N: new conversation.
- Ctrl+K: search history.
- Hover a reply to reveal copy, read aloud and retry; the last reply keeps them visible.
- Esc: stop model generation.

## Verification

```powershell
flutter analyze
flutter test
flutter build windows --release
```

Tests cover fragmented SSE/UTF-8 parsing, provider errors and streamed error objects, the history attachment budget, request construction, cancellation/session isolation, persisted history/attachments/shortcuts, recovery from a corrupt primary file, deletion boundaries, navigation/search, five locales, narrow/compact layouts, and code/math/table rendering.

UI tests generate review images in `build/qa/`. They use real Windows fonts when available. Actual external AI calls require the user's credentials and are not part of automated tests.

## Platform scope

Windows is the supported target for this iteration. macOS, Linux and Android need platform-specific screen capture, permission and window behavior testing before release.
