#ifndef PYTHON_BRIDGE_H
#define PYTHON_BRIDGE_H

/// One line of yt-dlp output: (context, UTF-8 text, 1 for standard error).
typedef void (*jp_line_callback)(void *context, const char *line, int is_error);

/// Starts the embedded Python interpreter. `home` is the bundle's python folder, `app` the folder with
/// jethriki_host.py, `packages` the bundled site-packages, `override` a newer yt-dlp downloaded in the app
/// (or NULL). Returns 0 on success; on failure, *error points to a message (static, don't free).
int jp_start(const char *home, const char *app, const char *packages, const char *override, const char **error);

/// Runs yt-dlp with the given arguments (not including the program name), delivering each output line to
/// `callback`. Blocks until yt-dlp finishes and returns its exit status. `token` identifies the run for jp_cancel.
int jp_run_ytdlp(int argc, const char *const *argv, jp_line_callback callback, void *context, long token);

/// Interrupts the yt-dlp run started with `token`, and any FFmpeg it is running.
void jp_cancel(long token);

/// Hands Python the JavaScriptCore functions that solve YouTube's challenges (see JavaScriptBridge.swift).
void jp_set_javascript(void *run, void *release);

/// The Python version, e.g. "3.15.2" (static).
const char *jp_python_version(void);

#endif
