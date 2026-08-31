#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *message) {
  fprintf(stderr, "mincore-residency: %s: %s\n", message, strerror(errno));
  exit(2);
}

int main(int argc, char **argv) {
  int require_zero = 0;
  const char *path = NULL;

  if (argc == 3 && strcmp(argv[1], "--require-zero") == 0) {
    require_zero = 1;
    path = argv[2];
  } else if (argc == 2) {
    path = argv[1];
  } else {
    fprintf(stderr,
            "Usage: mincore-residency [--require-zero] REGULAR_FILE\n");
    return 2;
  }

  const int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0) {
    fail("open");
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    fail("fstat");
  }
  if (!S_ISREG(st.st_mode)) {
    fprintf(stderr, "mincore-residency: target is not a regular file\n");
    return 2;
  }
  if (st.st_size < 0) {
    fprintf(stderr, "mincore-residency: target has an invalid size\n");
    return 2;
  }

  const long page_size_long = sysconf(_SC_PAGESIZE);
  if (page_size_long <= 0) {
    fail("sysconf(_SC_PAGESIZE)");
  }
  const uint64_t page_size = (uint64_t)page_size_long;
  const uint64_t file_bytes = (uint64_t)st.st_size;
  const uint64_t page_count =
      file_bytes == 0 ? 0 : 1 + ((file_bytes - 1) / page_size);

  uint64_t resident_pages = 0;
  uint64_t resident_file_bytes = 0;
  if (file_bytes != 0) {
    if (file_bytes > SIZE_MAX || page_count > SIZE_MAX) {
      fprintf(stderr, "mincore-residency: target is too large to map\n");
      return 2;
    }
    void *mapping = mmap(NULL, (size_t)file_bytes, PROT_READ, MAP_SHARED, fd, 0);
    if (mapping == MAP_FAILED) {
      fail("mmap");
    }
    unsigned char *residency = calloc((size_t)page_count, 1);
    if (residency == NULL) {
      fail("calloc");
    }
    if (mincore(mapping, (size_t)file_bytes, residency) != 0) {
      fail("mincore");
    }
    for (uint64_t i = 0; i < page_count; ++i) {
      if ((residency[i] & 1U) != 0) {
        ++resident_pages;
        const uint64_t page_start = i * page_size;
        const uint64_t remaining = file_bytes - page_start;
        resident_file_bytes += remaining < page_size ? remaining : page_size;
      }
    }
    free(residency);
    if (munmap(mapping, (size_t)file_bytes) != 0) {
      fail("munmap");
    }
  }
  if (close(fd) != 0) {
    fail("close");
  }

  printf("page_size_bytes=%" PRIu64 "\n", page_size);
  printf("file_bytes=%" PRIu64 "\n", file_bytes);
  printf("page_count=%" PRIu64 "\n", page_count);
  printf("resident_pages=%" PRIu64 "\n", resident_pages);
  printf("resident_file_bytes=%" PRIu64 "\n", resident_file_bytes);
  printf("residency_status=%s\n", resident_pages == 0 ? "PASS" : "FAIL");

  return require_zero && resident_pages != 0 ? 1 : 0;
}
