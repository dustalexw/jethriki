"""Runs yt-dlp inside the Jethriki iOS app.

iOS apps can't start other programs, so two things the desktop app gets from separate processes happen
in-process here:

* yt-dlp itself runs through `run()`, with its standard output and error delivered line by line to a
  C callback, exactly as the desktop app reads them from a child process.
* FFmpeg's `ffmpeg` and `ffprobe`, which yt-dlp starts with `subprocess`, run inside the app through the
  JethrikiFFmpeg library (jt_tool_run). `subprocess.Popen` is patched so that yt-dlp's own code doesn't
  change: pipes, communicate(), wait(), kill() all behave as with a real child process.

Any other program yt-dlp might try to start doesn't exist on iOS and is reported as not found.
"""
import ctypes
import errno
import itertools
import os
import subprocess
import sys
import threading

TOOLS = ("ffmpeg", "ffprobe")
_tools_lib = None
_fake_pids = itertools.count(1_000_000)


def tools_library():
    """The library with jt_tool_run, from JETHRIKI_TOOLS_LIB or already loaded into the app."""
    global _tools_lib
    if _tools_lib is None:
        path = os.environ.get("JETHRIKI_TOOLS_LIB")
        lib = ctypes.CDLL(path) if path else ctypes.CDLL(None)
        lib.jt_tool_run.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_char_p),
                                    ctypes.c_int, ctypes.c_int, ctypes.c_int]
        lib.jt_tool_run.restype = ctypes.c_int
        lib.jt_tool_cancel.argtypes = []
        lib.jt_tool_cancel.restype = None
        lib.jt_tool_version.restype = ctypes.c_char_p
        _tools_lib = lib
    return _tools_lib


def run_tool(argv, in_fd=0, out_fd=1, err_fd=2):
    """Runs ffmpeg or ffprobe in-process and returns its exit status."""
    args = [os.fsencode(a) for a in argv]
    array = (ctypes.c_char_p * len(args))(*args)
    name = os.path.basename(os.fsdecode(args[0])).encode()
    return tools_library().jt_tool_run(name, len(args), array, in_fd, out_fd, err_fd)


def _tool_name(args, executable):
    first = executable or (args if isinstance(args, (str, bytes, os.PathLike)) else (args[0] if args else ""))
    name = os.path.basename(os.fsdecode(first))
    return name if name in TOOLS else None


# MARK: subprocess

_original_execute_child = subprocess.Popen._execute_child
_original_wait = subprocess.Popen._wait
_original_poll = subprocess.Popen._internal_poll
_original_send_signal = subprocess.Popen.send_signal
_can_spawn = sys.platform not in ("ios", "tvos", "watchos") and not os.environ.get("JETHRIKI_NO_SPAWN")


def _execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env, startupinfo,
                   creationflags, shell, p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite, *rest, **kw):
    tool = None if shell else _tool_name(args, executable)
    if tool is None:
        if _can_spawn:
            return _original_execute_child(self, args, executable, preexec_fn, close_fds, pass_fds, cwd, env,
                                           startupinfo, creationflags, shell, p2cread, p2cwrite, c2pread,
                                           c2pwrite, errread, errwrite, *rest, **kw)
        program = args if isinstance(args, (str, bytes)) else (args[0] if args else "")
        self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)
        raise FileNotFoundError(errno.ENOENT, "Programs can't be started on iOS", os.fsdecode(program))

    argv = [args] if isinstance(args, (str, bytes)) else list(args)
    # Output that isn't piped would be inherited from yt-dlp, so it goes to the running job's log.
    inherit_out, inherit_err = _inherited or (1, 2)
    in_fd = p2cread if p2cread != -1 else 0
    out_fd = c2pwrite if c2pwrite != -1 else inherit_out
    err_fd = errwrite if errwrite != -1 else inherit_err

    def work():
        try:
            self._jt_status = run_tool(argv, in_fd, out_fd, err_fd)
        except BaseException:   # never leave the reader waiting forever
            self._jt_status = 255
        finally:
            # A real child's ends of the pipes close when it exits; the reader then sees end of file.
            self._close_pipe_fds(p2cread, p2cwrite, c2pread, c2pwrite, errread, errwrite)

    self.pid = next(_fake_pids)
    self._child_created = True
    self._jt_status = None
    self._jt_thread = threading.Thread(target=work, name=f"jethriki-{tool}", daemon=True)
    self._jt_thread.start()


def _wait(self, timeout):
    thread = getattr(self, "_jt_thread", None)
    if thread is None:
        return _original_wait(self, timeout)
    if self.returncode is None:
        thread.join(timeout)
        if thread.is_alive():
            raise subprocess.TimeoutExpired(self.args, timeout)
        self.returncode = self._jt_status
    return self.returncode


def _internal_poll(self, *args, **kwargs):
    thread = getattr(self, "_jt_thread", None)
    if thread is None:
        return _original_poll(self, *args, **kwargs)
    if self.returncode is None and not thread.is_alive():
        self.returncode = self._jt_status
    return self.returncode


def _send_signal(self, sig):
    if getattr(self, "_jt_thread", None) is None:
        return _original_send_signal(self, sig)
    if self.returncode is None:
        tools_library().jt_tool_cancel()


def patch_subprocess():
    subprocess.Popen._execute_child = _execute_child
    subprocess.Popen._wait = _wait
    subprocess.Popen._internal_poll = _internal_poll
    subprocess.Popen.send_signal = _send_signal


# MARK: yt-dlp

LINE_CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int)


class LineSink:
    """A text stream that hands each complete line (split on \\n or \\r, like the desktop app) to a callback."""
    encoding = "utf-8"
    errors = "replace"
    mode = "w"

    def __init__(self, emit, is_error):
        self._emit, self._is_error, self._pending = emit, is_error, ""
        self._lock = threading.Lock()

    def write(self, text):
        if not isinstance(text, str):
            text = bytes(text).decode("utf-8", "replace")
        with self._lock:
            data = self._pending + text
            start = 0
            for i, ch in enumerate(data):
                if ch in "\r\n":
                    if i > start:
                        self._emit(data[start:i], self._is_error)
                    start = i + 1
            self._pending = data[start:]
        return len(text)

    def flush(self):
        pass

    def close(self):
        with self._lock:
            if self._pending:
                self._emit(self._pending, self._is_error)
                self._pending = ""

    def isatty(self):
        return False

    def writable(self):
        return True

    def fileno(self):
        import io
        raise io.UnsupportedOperation("fileno")


_jobs = {}
_jobs_lock = threading.Lock()
_run_lock = threading.Lock()
_inherited = None   # (stdout, stderr) descriptors of the running job, for FFmpeg output that isn't piped


def _pipe_into(sink):
    """A descriptor whose output is written to `sink`, and the thread doing that."""
    read_end, write_end = os.pipe()

    def pump():
        with os.fdopen(read_end, "rb", buffering=0) as source:
            while chunk := source.read(65536):
                sink.write(chunk.decode("utf-8", "replace"))

    thread = threading.Thread(target=pump, name="jethriki-output", daemon=True)
    thread.start()
    return write_end, thread


def run(argv, callback_address, context, token):
    """Runs yt-dlp with `argv` (without the program name). Each output line goes to the C function at
    `callback_address` as (context, utf8_line, is_stderr). Returns yt-dlp's exit status.
    yt-dlp reads its output streams from `sys`, so one job runs at a time."""
    callback = LINE_CALLBACK(callback_address)

    def emit(line, is_error):
        callback(context, line.encode("utf-8", "replace"), 1 if is_error else 0)

    out, err = LineSink(emit, False), LineSink(emit, True)
    with _jobs_lock:
        _jobs[token] = threading.get_ident()
    try:
        with _run_lock:
            global _inherited
            saved = sys.stdout, sys.stderr, sys.argv
            sys.stdout, sys.stderr, sys.argv = out, err, ["yt-dlp"] + list(argv)
            (out_fd, out_pump), (err_fd, err_pump) = _pipe_into(out), _pipe_into(err)
            _inherited = (out_fd, err_fd)
            try:
                import yt_dlp
                install_javascriptcore()
                try:
                    status = yt_dlp.main(default_arguments(argv))
                except SystemExit as stop:
                    code = stop.code
                    if code is None:
                        status = 0
                    elif isinstance(code, int):
                        status = code
                    else:
                        err.write(str(code).lstrip("\n") + "\n")
                        status = 1
                except KeyboardInterrupt:
                    err.write("ERROR: Interrupted by user\n")
                    status = 1
                except BaseException as error:   # a crash in yt-dlp must not take the app down
                    import traceback
                    err.write("ERROR: " + "".join(traceback.format_exception(error)))
                    status = 1
                else:
                    status = status or 0
            finally:
                _inherited = None
                os.close(out_fd)
                os.close(err_fd)
                out_pump.join(5)
                err_pump.join(5)
                out.close()
                err.close()
                sys.stdout, sys.stderr, sys.argv = saved
    finally:
        with _jobs_lock:
            _jobs.pop(token, None)
    return int(status) if isinstance(status, int) else 1


def cancel(token):
    """Stops the yt-dlp job started with `token`: interrupts its thread and any FFmpeg it is running."""
    with _jobs_lock:
        ident = _jobs.get(token)
    if ident is None:
        return False
    ctypes.pythonapi.PyThreadState_SetAsyncExc(ctypes.c_ulong(ident), ctypes.py_object(KeyboardInterrupt))
    tools_library().jt_tool_cancel()
    return True


# MARK: JavaScript for YouTube

_js_functions = None   # (run, release) from the app, see set_javascript()
JS_RUN = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int))
JS_RELEASE = ctypes.CFUNCTYPE(None, ctypes.c_void_p)


def set_javascript(run_address, release_address):
    """Called by the app with its JavaScriptCore functions: run(script, &failed) -> malloc'd UTF-8 text, release(text)."""
    global _js_functions
    _js_functions = (JS_RUN(run_address), JS_RELEASE(release_address))


def _js_evaluate(script):
    """Runs `script` in JavaScriptCore and returns what it printed with console.log."""
    if _js_functions is None:
        raise RuntimeError("JavaScriptCore isn't available")
    run_js, release = _js_functions
    failed = ctypes.c_int(0)
    pointer = run_js(script.encode("utf-8"), ctypes.byref(failed))
    try:
        text = ctypes.string_at(pointer).decode("utf-8", "replace") if pointer else ""
    finally:
        if pointer:
            release(pointer)
    if failed.value:
        raise RuntimeError(text or "JavaScript failed")
    return text


def _js_available():
    return _js_functions is not None


def install_javascriptcore():
    """Teaches yt-dlp a JavaScript runtime named "jsc": Apple's JavaScriptCore, built into iOS. YouTube needs a
    JavaScript runtime to unlock most formats; on a computer that is Deno or Node, which can't run on iOS.
    Uses yt-dlp's provider interface for its EJS challenge solver (bundled as the yt-dlp-ejs package).
    Returns False, leaving yt-dlp as it is, if this yt-dlp version's interface is different."""
    try:
        from yt_dlp.globals import supported_js_runtimes
        from yt_dlp.utils._jsruntime import JsRuntime, JsRuntimeInfo
        from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
        from yt_dlp.extractor.youtube.jsc.provider import (
            JsChallengeProviderError, register_preference, register_provider)
    except ImportError:
        return False
    if "jsc" in supported_js_runtimes.value:
        return True

    class JavaScriptCoreRuntime(JsRuntime):
        def _info(self):
            if not (_js_evaluate is not _ORIGINAL_JS_EVALUATE or _js_available()):
                return None
            return JsRuntimeInfo(name="jsc", path="JavaScriptCore", version="1.0", version_tuple=(1, 0), supported=True)

    @register_provider
    class JavaScriptCoreJCP(EJSBaseJCP):
        JS_RUNTIME_NAME = "jsc"
        PROVIDER_VERSION = "1.0"
        BUG_REPORT_LOCATION = "https://github.com/dustalexw/jethriki/issues"

        def _run_js_runtime(self, stdin, /):
            try:
                return _js_evaluate(stdin)
            except Exception as error:
                raise JsChallengeProviderError(f"JavaScriptCore: {error}")

    @register_preference(JavaScriptCoreJCP)
    def _preference(provider, requests):
        return 900

    supported_js_runtimes.value["jsc"] = JavaScriptCoreRuntime
    return True


_ORIGINAL_JS_EVALUATE = _js_evaluate


def default_arguments(argv):
    """yt-dlp options the app always wants on iOS, unless the arguments already set them."""
    extra = []
    if not any(a == "--js-runtimes" or a.startswith("--js-runtimes=") for a in argv):
        extra += ["--js-runtimes", "jsc"]
    if not any(a in ("--cache-dir", "--no-cache-dir", "--rm-cache-dir") for a in argv) and os.environ.get("JETHRIKI_CACHE_DIR"):
        extra += ["--cache-dir", os.environ["JETHRIKI_CACHE_DIR"]]
    return extra + list(argv)


def boot(packages, override):
    """Called once at start-up: adds the bundled packages and, ahead of them, a yt-dlp the user updated to."""
    import site
    site.addsitedir(packages)
    if override and os.path.exists(override):
        sys.path.insert(0, override)
    patch_subprocess()


def versions():
    """yt-dlp's version, and where it was loaded from."""
    import yt_dlp.version
    return yt_dlp.version.__version__, os.path.dirname(os.path.dirname(yt_dlp.__file__))


if sys.platform != "ios":   # the app calls boot(); scripts and tests import this module directly
    patch_subprocess()
