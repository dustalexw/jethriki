// Runs yt-dlp in the Python interpreter embedded in the app (see iOS/Python/app/jethriki_host.py).
#include <Python/Python.h>
#include <stdio.h>
#include <string.h>

#include "PythonBridge.h"

static PyObject *host;   // the jethriki_host module, once started
static char start_error[1024];

static int fail(const char *what, const char **error) {
    if (PyErr_Occurred()) {
        PyObject *exc = PyErr_GetRaisedException();
        PyObject *text = exc ? PyObject_Str(exc) : NULL;
        const char *detail = text ? PyUnicode_AsUTF8(text) : NULL;
        snprintf(start_error, sizeof start_error, "%s: %s", what, detail ? detail : "unknown error");
        Py_XDECREF(text);
        PyErr_SetRaisedException(exc);
        PyErr_Print();
    } else {
        snprintf(start_error, sizeof start_error, "%s", what);
    }
    if (error) *error = start_error;
    return 1;
}

int jp_start(const char *home, const char *app, const char *packages, const char *override, const char **error) {
    if (host) return 0;

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return fail(status.err_msg ? status.err_msg : "Python pre-initialization failed", error);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;   // the app owns signals; yt-dlp is stopped with jp_cancel
    config.use_system_logger = 1;
    status = PyConfig_SetBytesString(&config, &config.home, home);
    if (!PyStatus_Exception(status)) status = PyConfig_Read(&config);
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return fail(status.err_msg ? status.err_msg : "Python initialization failed", error);

    PyObject *sys_path = PySys_GetObject("path");   // borrowed
    PyObject *app_path = PyUnicode_DecodeFSDefault(app);
    if (!sys_path || !app_path || PyList_Append(sys_path, app_path) < 0) {
        Py_XDECREF(app_path);
        return fail("Couldn't set up Python's module path", error);
    }
    Py_DECREF(app_path);

    host = PyImport_ImportModule("jethriki_host");
    if (!host) return fail("Couldn't load the yt-dlp host", error);
    PyObject *booted = PyObject_CallMethod(host, "boot", "ss", packages, override ? override : "");
    if (!booted) { Py_CLEAR(host); return fail("Couldn't load yt-dlp", error); }
    Py_DECREF(booted);

    PyEval_SaveThread();   // release the GIL: runs happen on worker threads
    return 0;
}

int jp_run_ytdlp(int argc, const char *const *argv, jp_line_callback callback, void *context, long token) {
    if (!host) return 127;
    PyGILState_STATE gil = PyGILState_Ensure();
    int result = 1;
    PyObject *args = PyList_New(argc);
    for (int i = 0; args && i < argc; i++) {
        PyObject *item = PyUnicode_DecodeFSDefault(argv[i]);
        if (!item) { Py_CLEAR(args); break; }
        PyList_SET_ITEM(args, i, item);
    }
    if (args) {
        PyObject *status = PyObject_CallMethod(host, "run", "OKKl", args,
                                               (unsigned long long)(uintptr_t)callback,
                                               (unsigned long long)(uintptr_t)context, token);
        if (status) {
            result = (int)PyLong_AsLong(status);
            Py_DECREF(status);
        }
        Py_DECREF(args);
    }
    if (PyErr_Occurred()) PyErr_Print();
    PyGILState_Release(gil);
    return result;
}

void jp_cancel(long token) {
    if (!host) return;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *r = PyObject_CallMethod(host, "cancel", "l", token);
    Py_XDECREF(r);
    if (PyErr_Occurred()) PyErr_Print();
    PyGILState_Release(gil);
}

void jp_set_javascript(void *run, void *release) {
    if (!host) return;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *r = PyObject_CallMethod(host, "set_javascript", "KK",
                                      (unsigned long long)(uintptr_t)run, (unsigned long long)(uintptr_t)release);
    Py_XDECREF(r);
    if (PyErr_Occurred()) PyErr_Print();
    PyGILState_Release(gil);
}

const char *jp_python_version(void) { return PY_VERSION; }
