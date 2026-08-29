#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_TASKS 8192
#define PATH_BUFFER 4096
#define CLONE_UNTRACED_FLAG 0x00800000ULL

static pid_t tasks[MAX_TASKS];
static size_t task_count = 0;
static unsigned long long peak_tree_rss_bytes = 0;
static unsigned long long memory_limit_bytes = 0;
static int memory_limit_exceeded = 0;
static int proc_fd = -1;
static int peak_fd = -1;
static int memory_violation_fd = -1;
static FILE *evidence = NULL;
static unsigned long event_sequence = 0;
static volatile sig_atomic_t sample_due = 0;

static void fatal(const char *message) {
  perror(message);
  exit(125);
}

static int parse_fd(const char *value) {
  char *end = NULL;
  long parsed;
  if (strcmp(value, "-") == 0) return -1;
  errno = 0;
  parsed = strtol(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed < 0 || parsed > 1024) {
    fprintf(stderr, "exec-once: invalid inherited descriptor: %s\n", value);
    exit(125);
  }
  return (int)parsed;
}

static unsigned long long parse_bytes(const char *value) {
  char *end = NULL;
  unsigned long long parsed;
  errno = 0;
  parsed = strtoull(value, &end, 10);
  if (errno != 0 || end == value || *end != '\0' || parsed == 0) {
    fprintf(stderr, "exec-once: invalid memory limit: %s\n", value);
    exit(125);
  }
  return parsed;
}

static void sanitize(char *text) {
  unsigned char *p = (unsigned char *)text;
  while (*p != '\0') {
    if (*p == '\t' || *p == '\n' || *p == '\r' || *p < 0x20 || *p == 0x7f)
      *p = '?';
    ++p;
  }
}

static void record_event(const char *event, pid_t pid, pid_t related,
                         const char *detail) {
  char safe_detail[PATH_BUFFER];
  if (evidence == NULL) return;
  snprintf(safe_detail, sizeof(safe_detail), "%s", detail == NULL ? "" : detail);
  sanitize(safe_detail);
  fprintf(evidence, "%lu\t%s\t%d\t%d\t%s\n", ++event_sequence, event,
          (int)pid, (int)related, safe_detail);
  fflush(evidence);
}

static void add_task(pid_t pid) {
  size_t i;
  for (i = 0; i < task_count; ++i)
    if (tasks[i] == pid) return;
  if (task_count >= MAX_TASKS) {
    fprintf(stderr, "exec-once: process-tree tracking capacity exceeded\n");
    exit(125);
  }
  tasks[task_count++] = pid;
}

static void remove_task(pid_t pid) {
  size_t i;
  for (i = 0; i < task_count; ++i) {
    if (tasks[i] == pid) {
      tasks[i] = tasks[task_count - 1];
      --task_count;
      return;
    }
  }
}

static void kill_tasks(void) {
  size_t i;
  for (i = 0; i < task_count; ++i) kill(tasks[i], SIGKILL);
}

static ssize_t proc_read(pid_t pid, const char *leaf, char *buffer,
                         size_t capacity) {
  char path[64];
  int fd;
  ssize_t length;
  if (proc_fd < 0 || capacity == 0) return -1;
  snprintf(path, sizeof(path), "%d/%s", (int)pid, leaf);
  fd = openat(proc_fd, path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return -1;
  length = read(fd, buffer, capacity - 1);
  close(fd);
  if (length < 0) return -1;
  buffer[length] = '\0';
  return length;
}

static pid_t task_group_id(pid_t pid) {
  char status[4096];
  char *line;
  if (proc_read(pid, "status", status, sizeof(status)) < 0) return pid;
  line = strstr(status, "Tgid:");
  if (line == NULL) return pid;
  return (pid_t)strtol(line + 5, NULL, 10);
}

static unsigned long long resident_pages(pid_t pid) {
  char statm[256];
  char *cursor;
  if (proc_read(pid, "statm", statm, sizeof(statm)) < 0) return 0;
  cursor = statm;
  (void)strtoull(cursor, &cursor, 10);
  return strtoull(cursor, NULL, 10);
}

static void sample_tree_rss(void) {
  pid_t seen_groups[MAX_TASKS];
  size_t seen_count = 0;
  size_t i, j;
  unsigned long long pages = 0;
  unsigned long long bytes;
  long page_size;
  if (proc_fd < 0) return;
  for (i = 0; i < task_count; ++i) {
    pid_t group = task_group_id(tasks[i]);
    int duplicate = 0;
    for (j = 0; j < seen_count; ++j) {
      if (seen_groups[j] == group) {
        duplicate = 1;
        break;
      }
    }
    if (duplicate) continue;
    seen_groups[seen_count++] = group;
    pages += resident_pages(tasks[i]);
  }
  page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) page_size = 4096;
  bytes = pages * (unsigned long long)page_size;
  if (bytes > peak_tree_rss_bytes) peak_tree_rss_bytes = bytes;
  if (!memory_limit_exceeded && bytes > memory_limit_bytes) {
    memory_limit_exceeded = 1;
    record_event("memory-limit", 0, 0, "aggregate process-tree RSS exceeded");
    kill_tasks();
  }
}

static void alarm_handler(int signal_number) {
  (void)signal_number;
  sample_due = 1;
}

static void start_sampling_timer(void) {
  struct sigaction action;
  struct itimerval timer;
  memset(&action, 0, sizeof(action));
  action.sa_handler = alarm_handler;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGALRM, &action, NULL) != 0) fatal("exec-once sigaction");
  memset(&timer, 0, sizeof(timer));
  timer.it_interval.tv_usec = 100000;
  timer.it_value.tv_usec = 100000;
  if (setitimer(ITIMER_REAL, &timer, NULL) != 0) fatal("exec-once setitimer");
}

static void finish_evidence(void) {
  struct itimerval timer;
  memset(&timer, 0, sizeof(timer));
  (void)setitimer(ITIMER_REAL, &timer, NULL);
  sample_tree_rss();
  if (peak_fd >= 0)
    dprintf(peak_fd, "%llu\n", peak_tree_rss_bytes);
  if (memory_violation_fd >= 0)
    dprintf(memory_violation_fd, "%s\n", memory_limit_exceeded ? "yes" : "no");
  record_event("summary", 0, 0,
               memory_limit_exceeded ? "memory_limit_exceeded=yes"
                                     : "memory_limit_exceeded=no");
  if (evidence != NULL) fclose(evidence);
}

static void trace_exec_syscalls(void) {
  struct sock_filter filter[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (unsigned int)offsetof(struct seccomp_data, arch)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 0, 7),
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (unsigned int)offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 59, 4, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 322, 3, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 56, 2, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 435, 1, 0),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRACE),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_I386, 0, 7),
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
               (unsigned int)offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 11, 4, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 358, 3, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 120, 2, 0),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, 435, 1, 0),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
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

static void read_tracee_string(pid_t pid, uintptr_t address, char *buffer,
                               size_t capacity) {
  size_t offset = 0;
  union {
    long word;
    unsigned char bytes[sizeof(long)];
  } data;
  if (capacity == 0) return;
  buffer[0] = '\0';
  while (offset + 1 < capacity) {
    size_t i;
    errno = 0;
    data.word = ptrace(PTRACE_PEEKDATA, pid, (void *)(address + offset), NULL);
    if (data.word == -1 && errno != 0) break;
    for (i = 0; i < sizeof(long) && offset + 1 < capacity; ++i) {
      buffer[offset++] = (char)data.bytes[i];
      if (data.bytes[i] == '\0') return;
    }
  }
  buffer[capacity - 1] = '\0';
}

static void requested_exec_path(pid_t pid, char *buffer, size_t capacity) {
  struct __ptrace_syscall_info info;
  uintptr_t address = 0;
  long result;
  memset(&info, 0, sizeof(info));
  result = ptrace(PTRACE_GET_SYSCALL_INFO, pid, sizeof(info), &info);
  if (result < 0 || info.op != PTRACE_SYSCALL_INFO_SECCOMP) {
    snprintf(buffer, capacity, "path-unavailable");
    return;
  }
  if ((info.arch == AUDIT_ARCH_X86_64 && info.seccomp.nr == 322) ||
      (info.arch == AUDIT_ARCH_I386 && info.seccomp.nr == 358))
    address = (uintptr_t)info.seccomp.args[1];
  else
    address = (uintptr_t)info.seccomp.args[0];
  read_tracee_string(pid, address, buffer, capacity);
  if (buffer[0] == '\0') snprintf(buffer, capacity, "path-unavailable");
}

static int seccomp_syscall_info(pid_t pid, struct __ptrace_syscall_info *info) {
  long result;
  memset(info, 0, sizeof(*info));
  result = ptrace(PTRACE_GET_SYSCALL_INFO, pid, sizeof(*info), info);
  return result >= 0 && info->op == PTRACE_SYSCALL_INFO_SECCOMP;
}

static int is_exec_syscall(const struct __ptrace_syscall_info *info) {
  return (info->arch == AUDIT_ARCH_X86_64 &&
          (info->seccomp.nr == 59 || info->seccomp.nr == 322)) ||
         (info->arch == AUDIT_ARCH_I386 &&
          (info->seccomp.nr == 11 || info->seccomp.nr == 358));
}

static int is_clone_syscall(const struct __ptrace_syscall_info *info) {
  return (info->arch == AUDIT_ARCH_X86_64 &&
          (info->seccomp.nr == 56 || info->seccomp.nr == 435)) ||
         (info->arch == AUDIT_ARCH_I386 &&
          (info->seccomp.nr == 120 || info->seccomp.nr == 435));
}

static unsigned long long requested_clone_flags(
    pid_t pid, const struct __ptrace_syscall_info *info) {
  if (info->seccomp.nr != 435) return info->seccomp.args[0];
  {
    unsigned long long flags = 0;
    uintptr_t address = (uintptr_t)info->seccomp.args[0];
    long word;
    errno = 0;
    word = ptrace(PTRACE_PEEKDATA, pid, (void *)address, NULL);
    if (word == -1 && errno != 0) return CLONE_UNTRACED_FLAG;
    memcpy(&flags, &word,
           sizeof(word) < sizeof(flags) ? sizeof(word) : sizeof(flags));
    return flags;
  }
}

static void executed_image(pid_t pid, char *buffer, size_t capacity) {
  char path[64];
  ssize_t length;
  if (proc_fd < 0) {
    snprintf(buffer, capacity, "image-unavailable");
    return;
  }
  snprintf(path, sizeof(path), "%d/exe", (int)pid);
  length = readlinkat(proc_fd, path, buffer, capacity - 1);
  if (length < 0) {
    snprintf(buffer, capacity, "image-unavailable");
    return;
  }
  buffer[length] = '\0';
}

int main(int argc, char **argv) {
  int strict_policy;
  int status = 0;
  int root_exit = 125;
  pid_t child;
  long options;

  if (argc < 9) {
    fprintf(stderr,
            "usage: exec-once POLICY PROC_FD EVIDENCE_FD PEAK_FD "
            "MEMORY_VIOLATION_FD MEMORY_LIMIT WORKDIR EXECUTABLE [ARG ...]\n");
    return 125;
  }
  if (strcmp(argv[1], "strict") == 0)
    strict_policy = 1;
  else if (strcmp(argv[1], "process-tree") == 0)
    strict_policy = 0;
  else {
    fprintf(stderr, "exec-once: unsupported runtime policy: %s\n", argv[1]);
    return 125;
  }
  proc_fd = parse_fd(argv[2]);
  {
    int evidence_fd = parse_fd(argv[3]);
    peak_fd = parse_fd(argv[4]);
    memory_violation_fd = parse_fd(argv[5]);
    if (evidence_fd >= 0) {
      evidence = fdopen(dup(evidence_fd), "w");
      if (evidence == NULL) fatal("exec-once fdopen evidence");
      setvbuf(evidence, NULL, _IOLBF, 0);
      fprintf(evidence, "sequence\tevent\tpid\trelated_pid\tdetail\n");
    }
  }
  memory_limit_bytes = parse_bytes(argv[6]);
  if (chdir(argv[7]) != 0) fatal("exec-once chdir");

  child = fork();
  if (child < 0) fatal("exec-once fork");
  if (child == 0) {
    int fd;
    if (evidence != NULL) close(fileno(evidence));
    for (fd = 3; fd <= 1024; ++fd) close(fd);
    if (setpgid(0, 0) != 0) fatal("exec-once setpgid");
    if (ptrace(PTRACE_TRACEME, 0, NULL, NULL) != 0)
      fatal("exec-once PTRACE_TRACEME");
    raise(SIGSTOP);
    trace_exec_syscalls();
    execv(argv[8], &argv[8]);
    fatal("exec-once initial execv");
  }

  add_task(child);
  record_event("root-invocation", child, 0, argv[8]);
  if (waitpid(child, &status, 0) != child || !WIFSTOPPED(status))
    fatal("exec-once initial wait");
  options = PTRACE_O_EXITKILL | PTRACE_O_TRACEEXEC | PTRACE_O_TRACEFORK |
            PTRACE_O_TRACEVFORK | PTRACE_O_TRACECLONE |
            PTRACE_O_TRACESECCOMP;
  if (ptrace(PTRACE_SETOPTIONS, child, NULL, (void *)options) != 0)
    fatal("exec-once PTRACE_SETOPTIONS");

  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once initial PTRACE_CONT");
  if (waitpid(child, &status, __WALL) != child || !WIFSTOPPED(status) ||
      ((unsigned)status >> 16) != PTRACE_EVENT_SECCOMP) {
    fprintf(stderr, "exec-once: declared executable did not reach execve\n");
    kill_tasks();
    finish_evidence();
    return 126;
  }
  record_event("declared-exec", child, 0, argv[8]);
  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once declared PTRACE_CONT");
  if (waitpid(child, &status, __WALL) != child || !WIFSTOPPED(status) ||
      ((unsigned)status >> 16) != PTRACE_EVENT_EXEC) {
    fprintf(stderr, "exec-once: declared executable did not start\n");
    kill_tasks();
    finish_evidence();
    return 126;
  }
  {
    char image[PATH_BUFFER];
    executed_image(child, image, sizeof(image));
    record_event("exec-image", child, 0, image);
  }
  if (ptrace(PTRACE_CONT, child, NULL, NULL) != 0)
    fatal("exec-once initial executable PTRACE_CONT");
  start_sampling_timer();

  while (task_count > 0) {
    pid_t pid = waitpid(-1, &status, __WALL);
    if (pid < 0) {
      if (errno == EINTR) {
        if (sample_due) {
          sample_due = 0;
          sample_tree_rss();
        }
        continue;
      }
      if (errno == ECHILD) break;
      fatal("exec-once waitpid");
    }
    sample_tree_rss();
    if (WIFEXITED(status) || WIFSIGNALED(status)) {
      char detail[64];
      if (WIFEXITED(status))
        snprintf(detail, sizeof(detail), "exit=%d", WEXITSTATUS(status));
      else
        snprintf(detail, sizeof(detail), "signal=%d", WTERMSIG(status));
      record_event("task-exit", pid, 0, detail);
      if (pid == child)
        root_exit = WIFEXITED(status) ? WEXITSTATUS(status)
                                      : 128 + WTERMSIG(status);
      remove_task(pid);
      continue;
    }
    if (!WIFSTOPPED(status)) continue;

    {
      unsigned event = (unsigned)status >> 16;
      int signal_number = WSTOPSIG(status);
      if (event == PTRACE_EVENT_FORK || event == PTRACE_EVENT_VFORK ||
          event == PTRACE_EVENT_CLONE) {
        unsigned long new_pid = 0;
        if (ptrace(PTRACE_GETEVENTMSG, pid, NULL, &new_pid) == 0 && new_pid > 0) {
          int new_status = 0;
          pid_t waited;
          add_task((pid_t)new_pid);
          record_event(event == PTRACE_EVENT_CLONE ? "clone" :
                       event == PTRACE_EVENT_VFORK ? "vfork" : "fork",
                       pid, (pid_t)new_pid, "");
          do {
            waited = waitpid((pid_t)new_pid, &new_status, __WALL);
            if (waited < 0 && errno == EINTR) sample_tree_rss();
          } while (waited < 0 && errno == EINTR);
          if (waited != (pid_t)new_pid || !WIFSTOPPED(new_status)) {
            fprintf(stderr, "exec-once: could not start a traced child task\n");
            kill_tasks();
            finish_evidence();
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
        struct __ptrace_syscall_info info;
        if (!seccomp_syscall_info(pid, &info)) {
          record_event("syscall-rejected", pid, 0, "metadata-unavailable");
          fprintf(stderr, "exec-once: could not inspect a traced syscall\n");
          kill_tasks();
          while (waitpid(-1, &status, __WALL) > 0) {}
          finish_evidence();
          return 126;
        }
        if (is_exec_syscall(&info)) {
          char path[PATH_BUFFER];
          requested_exec_path(pid, path, sizeof(path));
          if (strict_policy) {
            record_event("exec-rejected", pid, 0, path);
            fprintf(stderr,
                    "exec-once: rejected an undeclared additional executable invocation\n");
            kill_tasks();
            while (waitpid(-1, &status, __WALL) > 0) {}
            finish_evidence();
            return 126;
          }
          record_event("exec-permitted", pid, 0, path);
        } else if (is_clone_syscall(&info)) {
          unsigned long long flags = requested_clone_flags(pid, &info);
          if ((flags & CLONE_UNTRACED_FLAG) != 0) {
            record_event("clone-rejected", pid, 0, "CLONE_UNTRACED");
            fprintf(stderr,
                    "exec-once: rejected CLONE_UNTRACED outside the monitored process tree\n");
            kill_tasks();
            while (waitpid(-1, &status, __WALL) > 0) {}
            finish_evidence();
            return 126;
          }
          record_event("clone-request", pid, 0, "tracked");
        } else {
          record_event("syscall-rejected", pid, 0, "unexpected-seccomp-event");
          fprintf(stderr,
                  "exec-once: rejected an unexpected traced syscall\n");
          kill_tasks();
          while (waitpid(-1, &status, __WALL) > 0) {}
          finish_evidence();
          return 126;
        }
      } else if (event == PTRACE_EVENT_EXEC) {
        char image[PATH_BUFFER];
        if (strict_policy) {
          record_event("exec-rejected", pid, 0, "untrapped-exec-event");
          fprintf(stderr,
                  "exec-once: rejected an undeclared additional executable invocation\n");
          kill_tasks();
          while (waitpid(-1, &status, __WALL) > 0) {}
          finish_evidence();
          return 126;
        }
        executed_image(pid, image, sizeof(image));
        record_event("exec-image", pid, 0, image);
      }

      {
        int deliver = 0;
        if (event == 0 && signal_number != SIGSTOP && signal_number != SIGTRAP)
          deliver = signal_number;
        if (ptrace(PTRACE_CONT, pid, NULL, (void *)(long)deliver) != 0 &&
            errno != ESRCH)
          fatal("exec-once PTRACE_CONT");
      }
    }
  }
  finish_evidence();
  return memory_limit_exceeded ? 137 : root_exit;
}
