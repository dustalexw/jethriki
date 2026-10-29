/* What the tools call instead of the C library's stdio streams, exit() and signal functions (jt_tools.c). */
#ifndef JT_SHIM_H
#define JT_SHIM_H

#include <signal.h>
#include <stdio.h>

FILE *jt_stdout(void);
FILE *jt_stderr(void);
void jt_exit(int code) __attribute__((noreturn));
typedef void (*jt_sighandler)(int);
jt_sighandler jt_signal(int sig, jt_sighandler handler);
int jt_sigaction(int sig, const struct sigaction *action, struct sigaction *old);
/* The tools' main() functions, renamed on the command line, and ffmpeg's cancel hook (jt_ffmpeg_wrap.c). */
int jt_ffmpeg_main(int argc, char **argv);
int jt_ffprobe_main(int argc, char **argv);
void jt_ffmpeg_cancel(void);

#endif
