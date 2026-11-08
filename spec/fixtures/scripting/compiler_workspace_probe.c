#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <linux/falloc.h>
#include <linux/fs.h>
#include <time.h>
#include <unistd.h>

static int denied(void) { return errno == EACCES || errno == EPERM ? 77 : 2; }

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (strcmp(argv[1], "--identity") == 0) {
        printf("%ld:%ld:%d", (long)getuid(), (long)getgid(), getgroups(0, NULL));
        return 0;
    }
    if (strcmp(argv[1], "--self-signal") == 0) return raise(SIGCONT) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--group") == 0) return setpgid(0, 0) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--session") == 0) return setsid() == -1 ? denied() : 0;
    if (strcmp(argv[1], "--namespace") == 0) return unshare(CLONE_NEWUSER) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--fork") == 0) {
        pid_t child = fork();
        if (child < 0) return denied();
        if (child == 0) _exit(0);
        return waitpid(child, NULL, 0) == child ? 0 : 2;
    }
    if (strcmp(argv[1], "--memfd") == 0) {
        int fd = (int)syscall(SYS_memfd_create, "finite-probe", 0);
        if (fd < 0) return denied();
        close(fd);
        return 0;
    }
    if (strcmp(argv[1], "--fd-limit") == 0) {
        struct rlimit limit;
        if (getrlimit(RLIMIT_NOFILE, &limit) != 0) return 2;
        printf("%lu:%lu", (unsigned long)limit.rlim_cur, (unsigned long)limit.rlim_max);
        return 0;
    }
    if (argc < 3) return 2;
    if (strcmp(argv[1], "--signal") == 0) return kill((pid_t)strtol(argv[2], NULL, 10), SIGCONT) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--peer-limit") == 0) {
        struct rlimit limit = { 0, 0 };
        return prlimit((pid_t)strtol(argv[2], NULL, 10), RLIMIT_CPU, &limit, NULL) == 0 ? 0 : denied();
    }
    if (strcmp(argv[1], "--chmod") == 0) return chmod(argv[2], 0600) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--chown") == 0) return chown(argv[2], getuid(), getgid()) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--utime") == 0) return utimensat(AT_FDCWD, argv[2], NULL, 0) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--xattr") == 0) return setxattr(argv[2], "user.probe", "x", 1, 0) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--remove") == 0) return unlink(argv[2]) == 0 ? 0 : denied();
    if (strcmp(argv[1], "--fallocate") == 0 || strcmp(argv[1], "--file-ioctl") == 0) {
        int fd = open(argv[2], O_WRONLY);
        if (fd < 0) return denied();
        int result = strcmp(argv[1], "--fallocate") == 0 ? fallocate(fd, FALLOC_FL_KEEP_SIZE, 0, 1) : ioctl(fd, FICLONE, -1);
        int status = result == 0 ? 0 : denied();
        close(fd);
        return status;
    }
    if (strcmp(argv[1], "--write") == 0) {
        int fd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) return denied();
        int ok = write(fd, "x", 1) == 1;
        close(fd);
        return ok ? 0 : 2;
    }
    if (strcmp(argv[1], "--read") == 0) {
        int fd = open(argv[2], O_RDONLY);
        if (fd < 0) return denied();
        char value;
        int ok = read(fd, &value, 1) == 1 && write(STDOUT_FILENO, &value, 1) == 1;
        close(fd);
        return ok ? 0 : 2;
    }
    return 2;
}
