/* ffmpeg.c plus a way to stop it from another thread without a signal: its own Ctrl-C handler. */
#include "fftools/ffmpeg.c"

void jt_ffmpeg_cancel(void) { sigterm_handler(SIGINT); }
