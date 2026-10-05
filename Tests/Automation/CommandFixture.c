#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Exercises real child-process behavior without a shell or user workflows. */
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (strcmp(argv[1], "normal") == 0) {
        fputs("stdout fixture\n", stdout);
        fputs("stderr fixture\n", stderr);
        return 7;
    }
    if (strcmp(argv[1], "inherited") == 0) {
        pid_t child = fork();
        if (child < 0) return 3;
        if (child == 0) {
            /* The child keeps both write ends open beyond the runner deadline. */
            sleep(2);
            _exit(0);
        }
        return 0;
    }
    if (strcmp(argv[1], "ignore-term") == 0) {
        signal(SIGTERM, SIG_IGN);
        sleep(5);
        return 0;
    }
    return 2;
}
