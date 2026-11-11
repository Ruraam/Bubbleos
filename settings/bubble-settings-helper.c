/*
 * bubble-settings-helper - privileged account operations for bubble-settings
 *
 * This program is executed through pkexec (see org.bubbleos.settings.policy).
 * It never runs setuid and validates every argument again, so a compromised
 * GTK frontend cannot turn it into a generic root shell.
 *
 * Commands:
 *   add USER GECOS ADMIN CREATE_HOME   (password on stdin)
 *   passwd USER FORCE                  (password on stdin)
 *   delete USER REMOVE_HOME
 *   --version
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define HELPER_VERSION "0.1.0"
#define MAX_PASSWORD 512
#define MAX_GECOS 128
#define MIN_UID 1000
#define MAX_UID 59999

static void die(const char *fmt, ...) __attribute__((noreturn));

static void die(const char *fmt, ...)
{
    va_list args;

    fputs("bubble-settings-helper: ", stderr);
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    fputc('\n', stderr);
    exit(EXIT_FAILURE);
}

static bool parse_flag(const char *value)
{
    if (strcmp(value, "0") == 0) {
        return false;
    }
    if (strcmp(value, "1") == 0) {
        return true;
    }
    die("invalid boolean argument: %s", value);
}

static bool valid_username(const char *name)
{
    size_t length;
    const unsigned char *cursor;

    if (name == NULL || *name == '\0') {
        return false;
    }
    length = strlen(name);
    if (length > 32) {
        return false;
    }
    if (!(islower((unsigned char)name[0]) || name[0] == '_')) {
        return false;
    }
    for (cursor = (const unsigned char *)name + 1; *cursor != '\0'; cursor++) {
        if (!(islower(*cursor) || isdigit(*cursor) || *cursor == '_' ||
              *cursor == '-')) {
            return false;
        }
    }
    return true;
}

static void validate_gecos(const char *gecos)
{
    if (strlen(gecos) > MAX_GECOS) {
        die("the full name is too long (maximum %d bytes)", MAX_GECOS);
    }
    for (const unsigned char *cursor = (const unsigned char *)gecos; *cursor;
         cursor++) {
        if (*cursor == ':' || *cursor == '\n' || *cursor == '\r') {
            die("the full name contains an invalid character");
        }
        if (*cursor < 0x20 && *cursor != '\t') {
            die("the full name contains a control character");
        }
    }
}

static bool human_account(const struct passwd *pw)
{
    if (pw == NULL || pw->pw_name == NULL || pw->pw_uid < MIN_UID ||
        pw->pw_uid > MAX_UID) {
        return false;
    }
    if (strcmp(pw->pw_name, "nobody") == 0) {
        return false;
    }
    if (pw->pw_shell == NULL || *pw->pw_shell == '\0' ||
        strstr(pw->pw_shell, "nologin") != NULL ||
        strstr(pw->pw_shell, "/false") != NULL) {
        return false;
    }
    return true;
}

static bool account_is_admin(const char *name)
{
    struct group *group = getgrnam("sudo");

    if (group == NULL || group->gr_mem == NULL) {
        return false;
    }
    for (char **member = group->gr_mem; *member != NULL; member++) {
        if (strcmp(*member, name) == 0) {
            return true;
        }
    }
    return false;
}

static int count_admins_except(const char *excluded)
{
    struct passwd *pw;
    int count = 0;

    setpwent();
    while ((pw = getpwent()) != NULL) {
        if (!human_account(pw)) {
            continue;
        }
        if (excluded != NULL && strcmp(pw->pw_name, excluded) == 0) {
            continue;
        }
        if (account_is_admin(pw->pw_name)) {
            count++;
        }
    }
    endpwent();
    return count;
}

static uid_t pkexec_uid(void)
{
    const char *value = getenv("PKEXEC_UID");
    char *end = NULL;
    unsigned long parsed;

    if (value == NULL || *value == '\0') {
        return (uid_t)-1;
    }
    errno = 0;
    parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > UINT_MAX) {
        die("invalid PKEXEC_UID from the authentication agent");
    }
    return (uid_t)parsed;
}

static int run_command(char *const argv[], bool quiet)
{
    pid_t pid;
    int status;

    pid = fork();
    if (pid < 0) {
        die("cannot fork: %s", strerror(errno));
    }
    if (pid == 0) {
        if (quiet) {
            int nullfd = open("/dev/null", O_WRONLY);
            if (nullfd >= 0) {
                dup2(nullfd, STDOUT_FILENO);
                close(nullfd);
            }
        }
        execv(argv[0], argv);
        fprintf(stderr, "bubble-settings-helper: cannot run %s: %s\n", argv[0],
                strerror(errno));
        _exit(127);
    }
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            die("cannot wait for %s: %s", argv[0], strerror(errno));
        }
    }
    if (!WIFEXITED(status)) {
        return 128;
    }
    return WEXITSTATUS(status);
}

static bool write_all(int fd, const char *buffer, size_t length)
{
    size_t written = 0;

    while (written < length) {
        ssize_t got = write(fd, buffer + written, length - written);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        written += (size_t)got;
    }
    return true;
}

static void read_password(char *buffer, size_t size)
{
    size_t used = 0;

    for (;;) {
        ssize_t got;

        if (used + 1 >= size) {
            die("the password is too long (maximum %zu bytes)", size - 1);
        }
        got = read(STDIN_FILENO, buffer + used, size - 1 - used);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            die("cannot read the password: %s", strerror(errno));
        }
        if (got == 0) {
            break;
        }
        used += (size_t)got;
    }
    buffer[used] = '\0';
    if (used > 0 && buffer[used - 1] == '\n') {
        buffer[--used] = '\0';
    }
    if (used < 8) {
        die("the password must contain at least 8 characters");
    }
    for (size_t i = 0; i < used; i++) {
        unsigned char c = (unsigned char)buffer[i];
        if (c == '\n' || c == '\r' || c == '\0' || c == 0x7f ||
            (c < 0x20 && c != '\t')) {
            die("the password contains an invalid control character");
        }
    }
}

static bool set_password(const char *user, const char *password)
{
    char *const argv[] = {"/usr/sbin/chpasswd", NULL};
    int pipefd[2];
    pid_t pid;
    int status;
    size_t length = strlen(user) + 1 + strlen(password) + 1;
    char *payload;
    bool written;

    if (pipe(pipefd) < 0) {
        fprintf(stderr, "bubble-settings-helper: cannot create pipe: %s\n",
                strerror(errno));
        return false;
    }
    pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        fprintf(stderr, "bubble-settings-helper: cannot fork: %s\n",
                strerror(errno));
        return false;
    }
    if (pid == 0) {
        close(pipefd[1]);
        if (dup2(pipefd[0], STDIN_FILENO) < 0) {
            _exit(127);
        }
        close(pipefd[0]);
        execv(argv[0], argv);
        _exit(127);
    }
    close(pipefd[0]);

    payload = malloc(length);
    if (payload == NULL) {
        close(pipefd[1]);
        fprintf(stderr, "bubble-settings-helper: out of memory\n");
        return false;
    }
    snprintf(payload, length, "%s:%s\n", user, password);
    written = write_all(pipefd[1], payload, length - 1);
    memset(payload, 0, length);
    free(payload);
    close(pipefd[1]);

    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            fprintf(stderr, "bubble-settings-helper: cannot wait for chpasswd: %s\n",
                    strerror(errno));
            return false;
        }
    }
    if (!written || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "bubble-settings-helper: chpasswd failed\n");
        return false;
    }
    return true;
}

static void ensure_sudo_group(bool admin)
{
    if (admin && getgrnam("sudo") == NULL) {
        die("the sudo group is missing; install sudo before creating administrators");
    }
}

static int command_add(int argc, char **argv)
{
    const char *user;
    const char *gecos;
    bool admin;
    bool create_home;
    char password[MAX_PASSWORD];
    char *useradd_argv[12];
    int index = 0;
    int status;

    if (argc != 5) {
        die("usage: add USER GECOS ADMIN CREATE_HOME");
    }
    user = argv[1];
    gecos = argv[2];
    admin = parse_flag(argv[3]);
    create_home = parse_flag(argv[4]);

    if (!valid_username(user)) {
        die("invalid username: %s", user);
    }
    validate_gecos(gecos);
    ensure_sudo_group(admin);
    if (getpwnam(user) != NULL) {
        die("the account '%s' already exists", user);
    }
    read_password(password, sizeof(password));

    useradd_argv[index++] = "/usr/sbin/useradd";
    useradd_argv[index++] = create_home ? "-m" : "-M";
    useradd_argv[index++] = "-U";
    useradd_argv[index++] = "-s";
    useradd_argv[index++] = "/bin/bash";
    if (*gecos != '\0') {
        useradd_argv[index++] = "-c";
        useradd_argv[index++] = (char *)gecos;
    }
    if (admin) {
        useradd_argv[index++] = "-G";
        useradd_argv[index++] = "sudo";
    }
    useradd_argv[index++] = (char *)user;
    useradd_argv[index] = NULL;

    status = run_command(useradd_argv, false);
    if (status != 0) {
        memset(password, 0, sizeof(password));
        die("useradd failed with status %d", status);
    }
    if (!set_password(user, password)) {
        char *userdel_argv[4];
        int del_index = 0;

        memset(password, 0, sizeof(password));
        userdel_argv[del_index++] = "/usr/sbin/userdel";
        if (create_home) {
            userdel_argv[del_index++] = "-r";
        }
        userdel_argv[del_index++] = (char *)user;
        userdel_argv[del_index] = NULL;
        run_command(userdel_argv, true);
        die("chpasswd failed; the new account was removed");
    }
    memset(password, 0, sizeof(password));

    printf("created user %s%s\n", user, admin ? " (administrator)" : "");
    return EXIT_SUCCESS;
}

static int command_passwd(int argc, char **argv)
{
    const char *user;
    bool force;
    struct passwd *pw;
    char password[MAX_PASSWORD];

    if (argc != 3) {
        die("usage: passwd USER FORCE");
    }
    user = argv[1];
    force = parse_flag(argv[2]);
    if (!valid_username(user)) {
        die("invalid username: %s", user);
    }
    pw = getpwnam(user);
    if (pw == NULL) {
        die("the account '%s' does not exist", user);
    }
    if (!human_account(pw)) {
        die("refusing to change the password of a system account");
    }
    read_password(password, sizeof(password));
    if (!set_password(user, password)) {
        memset(password, 0, sizeof(password));
        die("the password was not changed");
    }
    memset(password, 0, sizeof(password));

    if (force) {
        char *const chage_argv[] = {"/usr/bin/chage", "-d", "0", (char *)user,
                                    NULL};
        if (run_command(chage_argv, false) != 0) {
            die("the password was changed but its expiration could not be set");
        }
    }
    printf("password updated for %s\n", user);
    return EXIT_SUCCESS;
}

static int command_delete(int argc, char **argv)
{
    const char *user;
    bool remove_home;
    struct passwd *pw;
    uid_t caller;
    char *userdel_argv[4];
    int index = 0;

    if (argc != 3) {
        die("usage: delete USER REMOVE_HOME");
    }
    user = argv[1];
    remove_home = parse_flag(argv[2]);
    if (!valid_username(user)) {
        die("invalid username: %s", user);
    }
    pw = getpwnam(user);
    if (pw == NULL) {
        die("the account '%s' does not exist", user);
    }
    if (!human_account(pw)) {
        die("refusing to delete a system account");
    }

    caller = pkexec_uid();
    if (caller != (uid_t)-1 && caller == pw->pw_uid) {
        die("refusing to delete the account that requested the operation");
    }
    if (account_is_admin(user) && count_admins_except(user) == 0) {
        die("refusing to delete the last administrator account");
    }

    userdel_argv[index++] = "/usr/sbin/userdel";
    if (remove_home) {
        userdel_argv[index++] = "-r";
    }
    userdel_argv[index++] = (char *)user;
    userdel_argv[index] = NULL;
    if (run_command(userdel_argv, false) != 0) {
        die("userdel failed; the account was not removed");
    }
    printf("deleted user %s\n", user);
    return EXIT_SUCCESS;
}

static void usage(const char *program)
{
    fprintf(stderr,
            "Usage: %s add USER GECOS ADMIN CREATE_HOME\n"
            "       %s passwd USER FORCE\n"
            "       %s delete USER REMOVE_HOME\n"
            "       %s --version\n",
            program, program, program, program);
}

int main(int argc, char **argv)
{
    const char *command;

    /* chpasswd can exit before the pipe is drained; the helper must report
     * the failure instead of dying from SIGPIPE. */
    signal(SIGPIPE, SIG_IGN);

    if (argc < 2) {
        usage(argv[0]);
        return EXIT_FAILURE;
    }
    command = argv[1];
    if (strcmp(command, "--version") == 0) {
        printf("bubble-settings-helper %s\n", HELPER_VERSION);
        return EXIT_SUCCESS;
    }
    if (strcmp(command, "--help") == 0 || strcmp(command, "-h") == 0) {
        usage(argv[0]);
        return EXIT_SUCCESS;
    }
    if (geteuid() != 0) {
        die("this helper must run as root through pkexec");
    }
    /* The command handlers treat argv[0] as the command name, matching the
     * documented "add USER GECOS ADMIN CREATE_HOME" form. */
    if (strcmp(command, "add") == 0) {
        return command_add(argc - 1, argv + 1);
    }
    if (strcmp(command, "passwd") == 0) {
        return command_passwd(argc - 1, argv + 1);
    }
    if (strcmp(command, "delete") == 0) {
        return command_delete(argc - 1, argv + 1);
    }
    usage(argv[0]);
    return EXIT_FAILURE;
}
