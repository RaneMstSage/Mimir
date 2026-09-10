/* Socket helpers mruby-socket cannot express portably: abstract-namespace connect, loopback
 * listen returning the ephemeral port, and O_NONBLOCK toggling on a raw fd. */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stddef.h>

static void sys_fail(mrb_state *mrb, const char *what) {
  mrb_raisef(mrb, E_RUNTIME_ERROR, "%s: %s", what, strerror(errno));
}

/* Inspect.connect_abstract(name) -> fd */
static mrb_value m_connect_abstract(mrb_state *mrb, mrb_value self) {
  const char *name; mrb_int len;
  mrb_get_args(mrb, "s", &name, &len);
  struct sockaddr_un addr; memset(&addr, 0, sizeof addr);
  addr.sun_family = AF_UNIX;
  if (len + 1 > (mrb_int)sizeof(addr.sun_path)) mrb_raise(mrb, E_ARGUMENT_ERROR, "socket name too long");
  addr.sun_path[0] = '\0';
  memcpy(addr.sun_path + 1, name, (size_t)len);
  socklen_t alen = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + len);
  int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) sys_fail(mrb, "socket");
  if (connect(fd, (struct sockaddr *)&addr, alen) != 0) { int e = errno; close(fd); errno = e; sys_fail(mrb, "connect"); }
  return mrb_fixnum_value(fd);
}

/* Inspect.listen_loopback(port = 0) -> [fd, port] */
static mrb_value m_listen_loopback(mrb_state *mrb, mrb_value self) {
  mrb_int port = 0; mrb_get_args(mrb, "|i", &port);
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) sys_fail(mrb, "socket");
  int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET; sa.sin_port = htons((uint16_t)port); sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { int e = errno; close(fd); errno = e; sys_fail(mrb, "bind"); }
  if (listen(fd, 16) != 0) { int e = errno; close(fd); errno = e; sys_fail(mrb, "listen"); }
  socklen_t sl = sizeof sa;
  if (getsockname(fd, (struct sockaddr *)&sa, &sl) != 0) { int e = errno; close(fd); errno = e; sys_fail(mrb, "getsockname"); }
  int ai = mrb_gc_arena_save(mrb);
  mrb_value pair = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, pair, mrb_fixnum_value(fd));
  mrb_ary_push(mrb, pair, mrb_fixnum_value(ntohs(sa.sin_port)));
  mrb_gc_arena_restore(mrb, ai);
  return pair;
}

/* Inspect.set_nonblock(fd, bool) */
static mrb_value m_set_nonblock(mrb_state *mrb, mrb_value self) {
  mrb_int fd; mrb_bool on; mrb_get_args(mrb, "ib", &fd, &on);
  int fl = fcntl((int)fd, F_GETFL, 0);
  if (fl < 0) sys_fail(mrb, "fcntl(F_GETFL)");
  fl = on ? (fl | O_NONBLOCK) : (fl & ~O_NONBLOCK);
  if (fcntl((int)fd, F_SETFL, fl) < 0) sys_fail(mrb, "fcntl(F_SETFL)");
  return mrb_nil_value();
}

void inspect_socket_init(mrb_state *mrb, struct RClass *mod) {
  mrb_define_module_function(mrb, mod, "connect_abstract", m_connect_abstract, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, mod, "listen_loopback",  m_listen_loopback,  MRB_ARGS_OPT(1));
  mrb_define_module_function(mrb, mod, "set_nonblock",     m_set_nonblock,     MRB_ARGS_REQ(2));
}
