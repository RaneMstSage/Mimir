package com.mstsage.inspect;

/** JNI surface of libinspect.so (see native/inspect.c). Methods are bound via RegisterNatives. */
final class Native {
    /** Set if the library failed to load; RubyRuntime reports it instead of crashing at class init. */
    static Throwable loadError;

    static {
        try {
            System.loadLibrary("inspect");
        } catch (Throwable t) {
            loadError = t;
        }
    }

    private Native() {}

    /** Runs the mruby VM on the calling thread until Ruby quits. Returns a status code. */
    static native int run(byte[] mrb, String bootJson);

    /** Enqueues a JSON event for Ruby; safe from any thread, never blocks. */
    static native void post(String json);

    /** Installs native signal handlers that write a report to the given path. */
    static native void initCrash(String path);
}
