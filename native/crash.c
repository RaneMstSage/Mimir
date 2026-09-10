/* Native crash reporter: without adb we cannot read tombstones, so on a fatal signal we write a
 * small report (signal, fault address, thread, unwound frames with dladdr symbolisation) to a
 * file the Java side shows on next launch and copies to Downloads. Then we re-raise the signal. */
#define _GNU_SOURCE 1
#include <jni.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>
#include <unwind.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <android/log.h>

static char g_crash_path[512];
static struct sigaction g_old[32];

typedef struct { void **frames; int max; int count; } bt_t;
static _Unwind_Reason_Code unwind_cb(struct _Unwind_Context *ctx, void *arg) {
  bt_t *bt = (bt_t *)arg;
  uintptr_t pc = _Unwind_GetIP(ctx);
  if (pc && bt->count < bt->max) bt->frames[bt->count++] = (void *)pc;
  return bt->count < bt->max ? _URC_NO_REASON : _URC_END_OF_STACK;
}

static void wr(int fd, const char *s) { (void)write(fd, s, strlen(s)); }

static void on_signal(int sig, siginfo_t *info, void *uctx) {
  int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  char buf[512];
  char tname[32] = "?"; prctl(PR_GET_NAME, tname, 0, 0, 0); tname[31] = 0;
  snprintf(buf, sizeof buf, "NATIVE CRASH: signal %d (%s) code %d addr %p in thread '%s'\n",
           sig, sig == SIGSEGV ? "SIGSEGV" : sig == SIGABRT ? "SIGABRT" : sig == SIGBUS ? "SIGBUS" : sig == SIGFPE ? "SIGFPE" : sig == SIGILL ? "SIGILL" : "?",
           info ? info->si_code : 0, info ? info->si_addr : NULL, tname);
  __android_log_write(ANDROID_LOG_ERROR, "InspectCrash", buf);
  if (fd >= 0) {
    wr(fd, buf);
    void *frames[48]; bt_t bt = { frames, 48, 0 };
    _Unwind_Backtrace(unwind_cb, &bt);
    for (int i = 0; i < bt.count; i++) {
      Dl_info dli; const char *lib = "?", *sym = "?"; uintptr_t off = (uintptr_t)frames[i];
      if (dladdr(frames[i], &dli)) {
        if (dli.dli_fname) { lib = strrchr(dli.dli_fname, '/') ? strrchr(dli.dli_fname, '/') + 1 : dli.dli_fname; off = (uintptr_t)frames[i] - (uintptr_t)dli.dli_fbase; }
        if (dli.dli_sname) sym = dli.dli_sname;
      }
      snprintf(buf, sizeof buf, "  #%02d pc %012lx  %s (%s)\n", i, (unsigned long)off, lib, sym);
      wr(fd, buf);
    }
    close(fd);
  }
  /* restore default and re-raise so the system still records the crash */
  sigaction(sig, &g_old[sig], NULL);
  raise(sig);
}

static void native_init_crash(JNIEnv *env, jclass cls, jstring path) {
  const char *p = (*env)->GetStringUTFChars(env, path, NULL);
  if (p) { strncpy(g_crash_path, p, sizeof g_crash_path - 1); (*env)->ReleaseStringUTFChars(env, path, p); }
  static char altstack[64 * 1024];
  stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
  sigaltstack(&ss, NULL);
  int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL };
  for (unsigned i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_signal; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(sigs[i], &sa, &g_old[sigs[i]]);
  }
}

int inspect_crash_register(JNIEnv *env, jclass native_cls) {
  JNINativeMethod m = { "initCrash", "(Ljava/lang/String;)V", (void *)native_init_crash };
  return (*env)->RegisterNatives(env, native_cls, &m, 1);
}
