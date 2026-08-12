#define _GNU_SOURCE
#include <errno.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void fatal(const char *message) {
  perror(message);
  exit(125);
}

static void trace_exec_syscalls(void) {
  struct sock_filter filter[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (unsigned int)offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_execve, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_execveat, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog program = {
      .len = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
      .filter = filter,
  };
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0)
    fatal("exec-once PR_SET_NO_NEW_PRIVS");
  if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program) != 0)
    fatal("exec-once PR_SET_SECCOMP");
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: exec-once WORKDIR EXECUTABLE [ARG ...]\n");
    return 125;
  }
  if (chdir(argv[1]) != 0) fatal("exec-once chdir");

  pid_t child = fork();
  if (child < 0) fatal("exec-once fork");
  if (child == 0) {
    if (setpgid(0, 0) != 0) fatal("exec-once setpgid");
    if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0)
      fatal("exec-once PTRACE_TRACEME");
    raise(SIGSTOP);
    trace_exec_syscalls();
    execv(argv[2], &argv[2]);
    fatal("exec-once initial execv");
  }

  int status = 0;
  if (waitpid(child, &status, 0) != child || !WIFSTOPPED(status))
    fatal("exec-once initial wait");
  long options = PTRACE_O_EXITKILL | PTRACE_O_TRACEEXEC | PTRACE_O_TRACEFORK |
                 PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE |
                 PTRACE_O_TRACESECCOMP;
  if (ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)options) != 0)
    fatal("exec-once PTRACE_SETOPTIONS");

  /* Permit exactly the declared initial executable transition. */
  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once initial PTRACE_CONT");
  if (waitpid(child, &status, __WALL) != child || !WIFSTOPPED(status) ||
      ((unsigned)status >> 16) != PTRACE_EVENT_SECCOMP) {
    fprintf(stderr, "exec-once: declared executable did not reach execve\n");
    kill(-child, SIGKILL);
    return 126;
  }
  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once declared PTRACE_CONT");
  if (waitpid(child, &status, __WALL) != child || !WIFSTOPPED(status) ||
      ((unsigned)status >> 16) != PTRACE_EVENT_EXEC) {
    fprintf(stderr, "exec-once: declared executable did not start\n");
    kill(-child, SIGKILL);
    return 126;
  }
  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once initial executable PTRACE_CONT");

  int root_exit = 125;
  int live = 1;
  while (live > 0) {
    pid_t pid = waitpid(-1, &status, __WALL);
    if (pid < 0) {
      if (errno == EINTR) continue;
      if (errno == ECHILD) break;
      fatal("exec-once waitpid");
    }
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
      if (pid == child) {
        root_exit = WIFEXITED(status) ? WEXITSTATUS(status)
                                      : 128 + WTERMSIG(status);
      }
      --live;
      continue;
    }
    if (!WIFSTOPPED(status)) continue;

    unsigned event = (unsigned)status >> 16;
    int signal_number = WSTOPSIG(status);
    if (event == PTRACE_EVENT_FORK || event == PTRACE_EVENT_VFORK ||
        event == PTRACE_EVENT_CLONE) {
      unsigned long new_pid = 0;
      if (ptrace(PTRACE_GETEVENTMSG, pid, NULL, &new_pid) == 0 && new_pid > 0) {
        ++live;
        /*
         * The new task is born ptrace-stopped.  Resuming only its parent
         * leaves it stopped forever; a parent that wait()s for that task can
         * then exit without ever observing its output.  Collect the initial
         * stop and resume the new task before continuing the task that
         * generated the fork/clone event.
         */
        int new_status = 0;
        pid_t waited;
        do {
          waited = waitpid((pid_t)new_pid, &new_status, __WALL);
        } while (waited < 0 && errno == EINTR);
        if (waited != (pid_t)new_pid || !WIFSTOPPED(new_status)) {
          fprintf(stderr, "exec-once: could not start a traced child task\n");
          kill(-child, SIGKILL);
          return 126;
        }
        if (ptrace(PTRACE_SETOPTIONS, (pid_t)new_pid, NULL,
                   (void *)options) != 0 && errno != ESRCH)
          fatal("exec-once child PTRACE_SETOPTIONS");
        if (ptrace(PTRACE_CONT, (pid_t)new_pid, NULL, NULL) != 0 &&
            errno != ESRCH)
          fatal("exec-once child PTRACE_CONT");
      }
    } else if (event == PTRACE_EVENT_SECCOMP) {
      fprintf(stderr,
              "exec-once: rejected an undeclared additional executable invocation\n");
      kill(-child, SIGKILL);
      while (waitpid(-1, &status, __WALL) > 0) {}
      return 126;
    } else if (event == PTRACE_EVENT_EXEC) {
      fprintf(stderr,
              "exec-once: rejected an undeclared additional executable invocation\n");
      kill(-child, SIGKILL);
      while (waitpid(-1, &status, __WALL) > 0) {}
      return 126;
    }

    int deliver = 0;
    if (event == 0 && signal_number != SIGSTOP && signal_number != SIGTRAP)
      deliver = signal_number;
    if (ptrace(PTRACE_CONT, pid, NULL, (void *)(long)deliver) != 0 &&
        errno != ESRCH)
      fatal("exec-once PTRACE_CONT");
  }
  return root_exit;
}
