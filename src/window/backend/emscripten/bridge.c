#include <emscripten/em_js.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*KnotsPasteCallback)(void *, const char *, uint32_t);
typedef void (*KnotsDisplayModeCallback)(void *, int);

void knots_emscripten_bridge_link(void) {}

EM_JS_DEPS(knots_emscripten_bridge,
           "$UTF8ToString,$lengthBytesUTF8,$stringToUTF8");

EM_JS(void, knots_emscripten_start_capture,
      (void *owner, const char *selector, KnotsPasteCallback paste_callback,
       KnotsDisplayModeCallback display_mode_callback), {
  const windows = globalThis.__knotsWindows ||
    (globalThis.__knotsWindows = new Map());
  if (windows.has(owner)) return;

  const canvas = document.querySelector(UTF8ToString(selector));
  if (!canvas) return;

  const catcher = document.createElement('textarea');
  catcher.setAttribute('readonly', String());
  catcher.setAttribute('aria-hidden', 'true');
  catcher.style.position = 'fixed';
  catcher.style.left = '-10000px';
  catcher.style.top = '0';
  catcher.style.width = '1px';
  catcher.style.height = '1px';
  catcher.style.opacity = '0';
  document.body.appendChild(catcher);

  const paste = (event) => {
    const target = event.target;
    if (target &&
        (target.isContentEditable || target.tagName === 'INPUT' ||
         (target.tagName === 'TEXTAREA' && target !== catcher))) return;

    const data = event.clipboardData &&
      event.clipboardData.getData('text/plain');
    if (data == null) return;

    const length = lengthBytesUTF8(data);
    const pointer = _malloc(length + 1);
    if (!pointer) return;
    stringToUTF8(data, pointer, length + 1);
    {{{ makeDynCall('vppi', 'paste_callback') }}}(owner, pointer, length);
    _free(pointer);

    event.preventDefault();
    if (document.activeElement === catcher) catcher.blur();
  };

  const fullscreen = () => {
    {{{ makeDynCall('vpi', 'display_mode_callback') }}}(
      owner, document.fullscreenElement === canvas ? 1 : 0);
  };

  const contextmenu = (event) => event.preventDefault();
  document.addEventListener('paste', paste, true);
  document.addEventListener('fullscreenchange', fullscreen);
  canvas.addEventListener('contextmenu', contextmenu);
  windows.set(owner, { canvas, catcher, paste, fullscreen, contextmenu });
});

EM_JS(void, knots_emscripten_stop_capture, (void *owner), {
  const windows = globalThis.__knotsWindows;
  const state = windows && windows.get(owner);
  if (!state) return;

  document.removeEventListener('paste', state.paste, true);
  document.removeEventListener('fullscreenchange', state.fullscreen);
  state.canvas.removeEventListener('contextmenu', state.contextmenu);
  state.catcher.remove();
  windows.delete(owner);
  if (windows.size === 0) delete globalThis.__knotsWindows;
});

EM_JS(void, knots_emscripten_prepare_paste, (void *owner), {
  const windows = globalThis.__knotsWindows;
  const state = windows && windows.get(owner);
  const catcher = state && state.catcher;
  if (!catcher) return;

  catcher.value = String();
  catcher.removeAttribute('readonly');
  catcher.focus();
  catcher.select();
  setTimeout(() => {
    catcher.setAttribute('readonly', String());
    if (document.activeElement === catcher) catcher.blur();
  }, 1000);
});

EM_JS(void, knots_emscripten_set_cursor,
      (const char *selector, const char *cursor), {
  const element = document.querySelector(UTF8ToString(selector));
  if (element) element.style.cursor = UTF8ToString(cursor);
});

EM_JS(void, knots_emscripten_set_title,
      (const char *title, size_t title_length), {
  document.title = UTF8ToString(title, Number(title_length));
});

EM_JS(int, knots_emscripten_copy,
      (const char *text, size_t text_length), {
  const textarea = document.createElement('textarea');
  textarea.value = UTF8ToString(text, Number(text_length));
  textarea.setAttribute('readonly', String());
  textarea.style.position = 'fixed';
  textarea.style.left = '-10000px';
  textarea.style.top = '0';
  document.body.appendChild(textarea);
  textarea.focus();
  textarea.select();

  let copied = false;
  try {
    copied = document.execCommand('copy');
  } catch (_) {}
  textarea.remove();
  return copied ? 1 : 0;
});
