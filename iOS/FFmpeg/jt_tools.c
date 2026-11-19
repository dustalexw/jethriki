/*
 * Runs FFmpeg's command-line tools (ffmpeg, ffprobe) inside the app. See jt_force.h for how their sources
 * are compiled so this works; this file is compiled normally.
 */
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "libavutil/avutil.h"
#include "libavutil/log.h"

#include "jt_shim.h"
#include "jt_tools.h"

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#endif

static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static FILE *run_out, *run_err;
static pthread_t run_thread;
static jmp_buf run_exit;
static int run_exit_code;
static atomic_int ffmpeg_running, cancel_requested;
static int log_prefix = 1;

// MARK: Streams, exit and signals for the tools

FILE *jt_stdout(void) { return run_out ? run_out : stdout; }
FILE *jt_stderr(void) { return run_err ? run_err : stderr; }

void jt_exit(int code) {
    if (run_out && pthread_equal(pthread_self(), run_thread)) {
        run_exit_code = code;
        longjmp(run_exit, 1);
    }
    // exit() from one of FFmpeg's worker threads: ending the thread is the closest safe thing.
    fprintf(jt_stderr(), "FFmpeg tried to exit from a worker thread (code %d)\n", code);
    pthread_exit(NULL);
}

jt_sighandler jt_signal(int sig, jt_sighandler handler) { (void)sig; (void)handler; return SIG_DFL; }
int jt_sigaction(int sig, const struct sigaction *action, struct sigaction *old) {
    (void)sig; (void)action;
    if (old) memset(old, 0, sizeof *old);
    return 0;
}

// MARK: Fresh globals for every run

typedef struct { uint8_t *start; size_t size; uint8_t *saved; } Region;
static Region regions[2];
static int region_count = -1;

#if defined(__APPLE__)
static void find_regions(void) {
    Dl_info info;
    region_count = 0;
    if (!dladdr((const void *)jt_tool_run, &info) || !info.dli_fbase) return;
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    const char *names[] = { "__jt_data", "__jt_bss" };
    for (int i = 0; i < 2; i++) {
        unsigned long size = 0;
        uint8_t *start = getsectiondata(header, "__DATA", names[i], &size);
        if (start && size) regions[region_count++] = (Region){ start, size, NULL };
    }
}
#else
extern uint8_t __start_jt_data[] __attribute__((weak)), __stop_jt_data[] __attribute__((weak));
extern uint8_t __start_jt_bss[] __attribute__((weak)), __stop_jt_bss[] __attribute__((weak));
static void find_regions(void) {
    region_count = 0;
    if (__start_jt_data && __stop_jt_data > __start_jt_data)
        regions[region_count++] = (Region){ __start_jt_data, (size_t)(__stop_jt_data - __start_jt_data), NULL };
    if (__start_jt_bss && __stop_jt_bss > __start_jt_bss)
        regions[region_count++] = (Region){ __start_jt_bss, (size_t)(__stop_jt_bss - __start_jt_bss), NULL };
}
#endif

/// The first time, remembers the tools' globals as loaded; every later time, puts them back.
static void reset_globals(void) {
    if (region_count < 0) {
        find_regions();
        for (int i = 0; i < region_count; i++) {
            regions[i].saved = malloc(regions[i].size);
            if (regions[i].saved) memcpy(regions[i].saved, regions[i].start, regions[i].size);
        }
        return;
    }
    for (int i = 0; i < region_count; i++)
        if (regions[i].saved) memcpy(regions[i].start, regions[i].saved, regions[i].size);
}

// MARK: Logging

static void log_to_run(void *avcl, int level, const char *format, va_list args) {
    if (level > av_log_get_level()) return;
    char line[2048];
    av_log_format_line2(avcl, level, format, args, line, sizeof line, &log_prefix);
    fputs(line, jt_stderr());
}

// MARK: Running

static int is_pipe_arg(const char *arg) {
    return !strcmp(arg, "-") || !strcmp(arg, "pipe:") || !strncmp(arg, "pipe:", 5);
}

int jt_tool_run(const char *tool, int argc, const char *const *argv, int in_fd, int out_fd, int err_fd) {
    const char *name = strrchr(tool, '/') ? strrchr(tool, '/') + 1 : tool;
    int probe = !strcmp(name, "ffprobe");
    if (!probe && strcmp(name, "ffmpeg")) return 127;

    pthread_mutex_lock(&run_lock);
    reset_globals();

    // argv with stdin interaction off and pipe arguments pointed at this run's descriptors.
    char **args = calloc((size_t)argc + 3, sizeof *args);
    char fd_args[3][24];
    snprintf(fd_args[0], sizeof fd_args[0], "pipe:%d", in_fd);
    snprintf(fd_args[1], sizeof fd_args[1], "pipe:%d", out_fd);
    snprintf(fd_args[2], sizeof fd_args[2], "pipe:%d", err_fd);
    int n = 0;
    args[n++] = (char *)name;
    if (!probe) args[n++] = (char *)"-nostdin";
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (is_pipe_arg(arg)) {
            int after_input = !strcmp(argv[i - 1], "-i");
            if (!strcmp(arg, "pipe:1")) arg = fd_args[1];
            else if (!strcmp(arg, "pipe:2")) arg = fd_args[2];
            else if (!strcmp(arg, "pipe:0") || after_input || probe) arg = fd_args[0];
            else if (!strcmp(arg, "-") || !strcmp(arg, "pipe:")) arg = fd_args[1];
        }
        args[n++] = (char *)arg;
    }
    args[n] = NULL;

    int out_copy = dup(out_fd), err_copy = dup(err_fd);
    run_out = out_copy >= 0 ? fdopen(out_copy, "w") : NULL;
    run_err = err_copy >= 0 ? fdopen(err_copy, "w") : NULL;
    if (!run_out || !run_err) {
        if (run_out) fclose(run_out); else if (out_copy >= 0) close(out_copy);
        if (run_err) fclose(run_err); else if (err_copy >= 0) close(err_copy);
        run_out = run_err = NULL;
        free(args);
        pthread_mutex_unlock(&run_lock);
        return 126;
    }
    setvbuf(run_out, NULL, _IOLBF, 0);
    setvbuf(run_err, NULL, _IONBF, 0);

    int level = av_log_get_level(), flags = av_log_get_flags();
    log_prefix = 1;
    av_log_set_callback(log_to_run);
    run_thread = pthread_self();
    run_exit_code = 0;

    int status;
    if (setjmp(run_exit) == 0) {
        if (probe) {
            status = jt_ffprobe_main(n, args);
        } else {
            atomic_store(&cancel_requested, 0);
            atomic_store(&ffmpeg_running, 1);
            status = jt_ffmpeg_main(n, args);
        }
    } else {
        status = run_exit_code;
    }
    atomic_store(&ffmpeg_running, 0);

    av_log_set_callback(av_log_default_callback);
    av_log_set_level(level);
    av_log_set_flags(flags);
    fclose(run_out);
    fclose(run_err);
    run_out = run_err = NULL;
    free(args);
    pthread_mutex_unlock(&run_lock);
    return status & 0xFF;
}

void jt_tool_cancel(void) {
    // FFmpeg counts signals and gives up hard after a few, so pass on only the first request.
    if (atomic_load(&ffmpeg_running) && !atomic_exchange(&cancel_requested, 1)) jt_ffmpeg_cancel();
}

const char *jt_tool_version(void) { return av_version_info(); }
