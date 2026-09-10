/*
 * Inspect Element — JNI shim hosting the mruby VM.
 *
 * Threading contract (see PLAN.md):
 *  - Native.run() is called once, on a dedicated Java "ruby" thread, and does not return until
 *    the Ruby side quits. That thread is the only one that ever touches `mrb`.
 *  - Native.post(json) may be called from any thread: it appends to a mutex-protected queue and
 *    writes one byte to a self-pipe so the Ruby select loop wakes up.
 *  - Ruby calls Inspect.emit(json) which invokes RubyRuntime.onCommand(String) (static); Java posts
 *    it to the main thread. Nothing crosses the boundary synchronously in the other direction.
 */
#define _GNU_SOURCE 1
#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include <mruby.h>
#include <mruby/irep.h>
#include <mruby/string.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/variable.h>
#include <mruby/version.h>

#define TAG "InspectRuby"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

/* ---- Java -> Ruby event queue ------------------------------------------------------------ */
typedef struct ev { char *json; struct ev *next; } ev_t;
static pthread_mutex_t q_lock = PTHREAD_MUTEX_INITIALIZER;
static ev_t *q_head = NULL, *q_tail = NULL;
static int wake_pipe[2] = { -1, -1 };

static void q_push(const char *json) {
  ev_t *e = (ev_t *)malloc(sizeof(ev_t));
  e->json = strdup(json); e->next = NULL;
  pthread_mutex_lock(&q_lock);
  if (q_tail) q_tail->next = e; else q_head = e;
  q_tail = e;
  pthread_mutex_unlock(&q_lock);
  char b = 1;
  if (wake_pipe[1] >= 0) (void)write(wake_pipe[1], &b, 1);
}

static char *q_pop(void) {
  pthread_mutex_lock(&q_lock);
  ev_t *e = q_head;
  if (e) { q_head = e->next; if (!q_head) q_tail = NULL; }
  pthread_mutex_unlock(&q_lock);
  if (!e) return NULL;
  char *j = e->json; free(e); return j;
}

/* ---- JNI globals --------------------------------------------------------------------------- */
static JavaVM *g_vm = NULL;
static jclass g_runtime_cls = NULL;      /* com.mstsage.inspect.RubyRuntime (global ref) */
static jmethodID g_on_command = NULL;    /* static void onCommand(String) */
static JNIEnv *g_ruby_env = NULL;        /* valid only on the ruby thread, during run() */

static void emit_to_java(const char *json) {
  JNIEnv *env = g_ruby_env;
  if (!env || !g_runtime_cls || !g_on_command) { LOGW("emit before Java is ready: %s", json); return; }
  jstring s = (*env)->NewStringUTF(env, json);
  if (!s) { (*env)->ExceptionClear(env); LOGW("emit: NewStringUTF failed"); return; }
  (*env)->CallStaticVoidMethod(env, g_runtime_cls, g_on_command, s);
  if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
  (*env)->DeleteLocalRef(env, s);
}

/* ---- Inspect module (Ruby-visible) --------------------------------------------------------- */
static mrb_value m_emit(mrb_state *mrb, mrb_value self) {
  const char *json; mrb_get_args(mrb, "z", &json);
  emit_to_java(json);
  return mrb_nil_value();
}

static mrb_value m_log(mrb_state *mrb, mrb_value self) {
  mrb_int level; const char *msg; mrb_get_args(mrb, "iz", &level, &msg);
  int prio = level <= 0 ? ANDROID_LOG_DEBUG : level == 1 ? ANDROID_LOG_INFO : level == 2 ? ANDROID_LOG_WARN : ANDROID_LOG_ERROR;
  __android_log_write(prio, TAG, msg);
  return mrb_nil_value();
}

static mrb_value m_wake_fd(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value(wake_pipe[0]); }

static mrb_value m_next_event(mrb_state *mrb, mrb_value self) {
  char *j = q_pop();
  if (!j) return mrb_nil_value();
  mrb_value s = mrb_str_new_cstr(mrb, j);
  free(j);
  return s;
}

static mrb_value m_pid(mrb_state *mrb, mrb_value self) { return mrb_fixnum_value((mrb_int)getpid()); }
static mrb_value m_version(mrb_state *mrb, mrb_value self) { return mrb_str_new_cstr(mrb, MRUBY_VERSION); }

void inspect_socket_init(mrb_state *mrb, struct RClass *mod);   /* inspect_socket.c */
int inspect_crash_register(JNIEnv *env, jclass native_cls);       /* crash.c */

static void define_inspect_module(mrb_state *mrb) {
  struct RClass *m = mrb_define_module(mrb, "Inspect");
  mrb_define_module_function(mrb, m, "emit",       m_emit,       MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, m, "log",        m_log,        MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, m, "wake_fd",    m_wake_fd,    MRB_ARGS_NONE());
  mrb_define_module_function(mrb, m, "next_event", m_next_event, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, m, "pid",        m_pid,        MRB_ARGS_NONE());
  mrb_define_module_function(mrb, m, "version",    m_version,    MRB_ARGS_NONE());
  inspect_socket_init(mrb, m);
}

/* Print an uncaught mruby exception (with backtrace) to logcat and hand it to Java. */
static void report_exception(mrb_state *mrb, const char *where) {
  if (!mrb->exc) return;
  mrb_value exc = mrb_obj_value(mrb->exc);
  mrb_value msg = mrb_funcall(mrb, exc, "inspect", 0);
  const char *m = mrb_string_p(msg) ? RSTRING_CSTR(mrb, msg) : "(exception)";
  LOGE("%s: %s", where, m);
  mrb_value bt = mrb_funcall(mrb, exc, "backtrace", 0);
  if (mrb_array_p(bt)) {
    for (mrb_int i = 0; i < RARRAY_LEN(bt); i++) {
      mrb_value line = mrb_ary_ref(mrb, bt, i);
      if (mrb_string_p(line)) LOGE("  at %s", RSTRING_CSTR(mrb, line));
    }
  }
  /* Best-effort JSON (escape quotes/backslashes/newlines). */
  size_t n = strlen(m); char *buf = (char *)malloc(n * 2 + 64); char *p = buf;
  p += sprintf(p, "{\"cmd\":\"fatal\",\"text\":\"%s: ", where);
  for (size_t i = 0; i < n; i++) {
    char c = m[i];
    if (c == '"' || c == '\\') { *p++ = '\\'; *p++ = c; }
    else if (c == '\n') { *p++ = '\\'; *p++ = 'n'; }
    else if ((unsigned char)c < 0x20) { *p++ = ' '; }
    else *p++ = c;
  }
  strcpy(p, "\"}");
  emit_to_java(buf);
  free(buf);
  mrb->exc = NULL;
}

/* ---- Native.run(byte[] mrb, String bootJson) ---------------------------------------------- */
static jint native_run(JNIEnv *env, jclass cls, jbyteArray irep, jstring boot) {
  g_ruby_env = env;
  mrb_state *mrb = mrb_open();
  if (!mrb) { LOGE("mrb_open failed"); return 1; }
  define_inspect_module(mrb);

  jsize len = (*env)->GetArrayLength(env, irep);
  jbyte *bytes = (*env)->GetByteArrayElements(env, irep, NULL);
  mrb_value ret = mrb_load_irep_buf(mrb, (const uint8_t *)bytes, (size_t)len);
  (*env)->ReleaseByteArrayElements(env, irep, bytes, JNI_ABORT);
  (void)ret;
  if (mrb->exc) { report_exception(mrb, "load"); mrb_close(mrb); g_ruby_env = NULL; return 2; }

  const char *boot_c = (*env)->GetStringUTFChars(env, boot, NULL);
  mrb_value boot_s = mrb_str_new_cstr(mrb, boot_c ? boot_c : "{}");
  if (boot_c) (*env)->ReleaseStringUTFChars(env, boot, boot_c);

  if (!mrb_class_defined(mrb, "App")) {
    LOGE("bytecode did not define App");
    emit_to_java("{\"cmd\":\"fatal\",\"text\":\"app.mrb did not define App\"}");
    mrb_close(mrb); g_ruby_env = NULL; return 4;
  }
  mrb_value app = mrb_const_get(mrb, mrb_obj_value(mrb->object_class), mrb_intern_lit(mrb, "App"));
  LOGI("mruby %s: starting App.run", MRUBY_VERSION);
  mrb_funcall(mrb, app, "run", 1, boot_s);
  int rc = 0;
  if (mrb->exc) { report_exception(mrb, "App.run"); rc = 3; }
  LOGI("App.run returned (%d)", rc);
  mrb_close(mrb);
  g_ruby_env = NULL;
  return rc;
}

/* ---- Native.post(String json) ------------------------------------------------------------- */
static void native_post(JNIEnv *env, jclass cls, jstring json) {
  const char *c = (*env)->GetStringUTFChars(env, json, NULL);
  if (!c) return;
  q_push(c);
  (*env)->ReleaseStringUTFChars(env, json, c);
}

static const JNINativeMethod methods[] = {
  { "run",  "([BLjava/lang/String;)I", (void *)native_run  },
  { "post", "(Ljava/lang/String;)V",   (void *)native_post },
};

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  g_vm = vm;
  JNIEnv *env;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) return -1;
  jclass native_cls = (*env)->FindClass(env, "com/mstsage/inspect/Native");
  if (!native_cls) return -1;
  if ((*env)->RegisterNatives(env, native_cls, methods, sizeof(methods) / sizeof(methods[0])) < 0) return -1;
  if (inspect_crash_register(env, native_cls) < 0) return -1;
  jclass rt = (*env)->FindClass(env, "com/mstsage/inspect/RubyRuntime");
  if (!rt) return -1;
  g_runtime_cls = (jclass)(*env)->NewGlobalRef(env, rt);
  g_on_command = (*env)->GetStaticMethodID(env, rt, "onCommand", "(Ljava/lang/String;)V");
  if (!g_on_command) return -1;
  if (pipe2(wake_pipe, O_CLOEXEC | O_NONBLOCK) != 0) { LOGE("pipe2: %s", strerror(errno)); return -1; }
  LOGI("libinspect loaded (mruby %s)", MRUBY_VERSION);
  return JNI_VERSION_1_6;
}
