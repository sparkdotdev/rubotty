/* A native executable for the descriptor-exec sandbox contract. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--environment") == 0) {
        for (char **entry = environ; *entry; ++entry) puts(*entry);
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--descriptors") == 0) {
        for (int fd = 0; fd < 1024; ++fd) {
            if (fcntl(fd, F_GETFD) != -1 || errno != EBADF) printf("%d\n", fd);
        }
        return 0;
    }
    if (argc == 2 && strcmp(argv[1], "--program-name") == 0) {
        puts(argv[0]);
        return 0;
    }
    FILE *input = argc > 1 ? fopen(argv[1], "r") : stdin;
    if (!input) {
        perror(argv[1]);
        return 1;
    }
    char buffer[4096];
    size_t count;
    while ((count = fread(buffer, 1, sizeof(buffer), input)) > 0) {
        if (fwrite(buffer, 1, count, stdout) != count) return 1;
    }
    int failed = ferror(input);
    if (input != stdin && fclose(input) != 0) failed = 1;
    return failed || fflush(stdout) != 0;
}
