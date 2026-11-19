/*
 * Force-included into every fftools source file (ffmpeg, ffprobe and their shared helpers) so the
 * command-line tools can run inside the app instead of as separate processes, which iOS doesn't allow.
 *
 * - stdout and stderr go to the FILE streams of the current run (pipes the caller reads), not the app's own.
 * - exit() returns to jt_tool_run() instead of ending the app.
 * - The tools can't install signal handlers: they would affect the whole app. Cancelling goes through
 *   jt_tool_cancel() instead.
 * - Interactive input is off.
 * - Every global and static variable is placed in the __jt_data / __jt_bss sections, which jt_tool_run()
 *   restores to their load-time contents before each run. The tools were written to run once per process
 *   and keep option flags and counters in globals; this gives every run a fresh copy.
 */
#ifndef JT_FORCE_H
#define JT_FORCE_H

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

#include "jt_shim.h"

#undef stdout
#undef stderr
#undef putchar
#undef getchar
#undef puts
#define stdout (jt_stdout())
#define stderr (jt_stderr())
#define printf(...) fprintf(stdout, __VA_ARGS__)
#define vprintf(format, args) vfprintf(stdout, format, args)
#define putchar(c) fputc((c), stdout)
#define puts(s) (fputs((s), stdout) < 0 ? EOF : fputc('\n', stdout))
#define getchar() EOF
#define exit(code) jt_exit(code)
#define signal(sig, handler) jt_signal((sig), (handler))
#define sigaction(sig, action, old) jt_sigaction((sig), (action), (old))

#if defined(__APPLE__)
#pragma clang section bss="__DATA,__jt_bss" data="__DATA,__jt_data"
#else
#pragma clang section bss="jt_bss" data="jt_data"
#endif

#endif
