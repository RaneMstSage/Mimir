package com.mstsage.inspect;

/** JNI surface of libinspect.so (see native/inspect.c). Methods are bound via RegisterNatives. */
final class Native {
    static {
        System.loadLibrary("inspect");
    }

    private Native() {}

    /** Runs the mruby VM on the calling thread until Ruby quits. Returns a status code. */
    static native int run(byte[] mrb, String bootJson);

    /** Enqueues a JSON event for Ruby; safe from any thread, never blocks. */
    static native void post(String json);
}
