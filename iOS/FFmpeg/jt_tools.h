#ifndef JT_TOOLS_H
#define JT_TOOLS_H

#ifdef __cplusplus
extern "C" {
#endif

/// Runs FFmpeg's `ffmpeg` or `ffprobe` command-line tool inside the app, like a child process would run.
/// `tool` is "ffmpeg" or "ffprobe" (a path whose last component is one of those also works).
/// `argv[0]` is ignored. The tool reads standard input from `in_fd` and writes standard output and
/// standard error to `out_fd` and `err_fd`; "pipe:0", "pipe:1", "pipe:2" and "-" arguments are mapped
/// onto them. The descriptors stay open; the caller closes them.
/// Runs one at a time: a second call waits for the first. Returns the tool's exit status.
int jt_tool_run(const char *tool, int argc, const char *const *argv, int in_fd, int out_fd, int err_fd);

/// Asks a running `ffmpeg` to stop, like pressing Ctrl-C: it finishes writing what it has and returns 255.
void jt_tool_cancel(void);

/// FFmpeg's version string, e.g. "9.0.2".
const char *jt_tool_version(void);

#ifdef __cplusplus
}
#endif
#endif
