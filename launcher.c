/*
 * launcher.c — Lori.app binary
 *
 * Зачем fork: launchd-процессы не получают TCC-разрешение на микрофон напрямую.
 * Lori.app (bundle ID: com.ri.lori) получил разрешение через GUI.
 * fork() оставляет Lori.app родителем — TCC видит правильный bundle ID.
 *
 * Строки PYTHON_BIN и SCRIPT_PATH подставляет install.sh.
 */
#include <unistd.h>
#include <sys/wait.h>

#define PYTHON_BIN  "PLACEHOLDER_PYTHON_BIN"
#define SCRIPT_PATH "PLACEHOLDER_SCRIPT_PATH"

int main() {
    pid_t pid = fork();
    if (pid == 0) {
        execl(PYTHON_BIN, "python3", SCRIPT_PATH, NULL);
        return 1;
    } else if (pid > 0) {
        int status;
        waitpid(pid, &status, 0);
    }
    return 0;
}
