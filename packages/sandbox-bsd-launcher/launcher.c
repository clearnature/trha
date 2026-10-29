/*
 * trha BSD sandbox launcher (T5.1 capsicum / T5.2 pledge+unveil).
 *
 * One source, two names:
 *   trha-sandbox-bsd   FreeBSD — pre-open the writable dirs, cap_rights_limit
 *                      them, then cap_enter().
 *   trha-sandbox-obsd  OpenBSD — unveil every path, lock with unveil(NULL,NULL),
 *                      then pledge(promises).
 *
 * On any other platform the launcher refuses to run the command (exit 126).
 * A launcher that cannot enforce its platform's boundary must never degrade
 * into a passthrough — that is the whole point of having it.
 *
 * The argument shapes are produced by the Haskell renderers
 * (Infrastructure.Sandbox.Backend.{FreeBSD,OpenBSD}) and pinned by golden
 * tests on the Haskell side; `--dry-run` here lets those shapes be checked
 * without a BSD host.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__FreeBSD__)
#include <sys/capsicum.h>
#define TRHA_PLATFORM "freebsd"
#elif defined(__OpenBSD__)
#define TRHA_PLATFORM "openbsd"
#else
#define TRHA_PLATFORM "unsupported"
#endif

#define MAX_UNVEILS 64

struct unveil_entry {
    char *path;   /* argv is writable; we split "path:perms" in place */
    char *perms;
};

struct options {
    const char *workspace;
    const char *scratch;
    const char *policy;
    const char *network;
    const char *pledge;
    struct unveil_entry unveils[MAX_UNVEILS];
    int unveil_count;
    int dry_run;
    char **command;
    int command_argc;
};

static void usage(const char *why)
{
    fprintf(stderr, "trha-sandbox: %s\n", why);
    fprintf(stderr,
        "usage: %s [--workspace DIR] [--scratch DIR] [--policy P] [--network N]\n"
        "          [--pledge PROMISES] [--unveil PATH:PERMS]... [--dry-run] -- CMD [ARG...]\n",
        "trha-sandbox");
}

static int parse_args(int argc, char **argv, struct options *o)
{
    memset(o, 0, sizeof(*o));
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--") == 0) {
            o->command = &argv[i + 1];
            o->command_argc = argc - i - 1;
            if (o->command_argc == 0) {
                usage("-- must be followed by a command");
                return -1;
            }
            return 0;
        }
        if (strcmp(arg, "--dry-run") == 0) {
            o->dry_run = 1;
            continue;
        }
        if (i + 1 >= argc) {
            usage("option needs a value");
            return -1;
        }
        char *value = argv[++i];
        if (strcmp(arg, "--workspace") == 0) {
            o->workspace = value;
        } else if (strcmp(arg, "--scratch") == 0) {
            o->scratch = value;
        } else if (strcmp(arg, "--policy") == 0) {
            o->policy = value;
        } else if (strcmp(arg, "--network") == 0) {
            o->network = value;
        } else if (strcmp(arg, "--pledge") == 0) {
            o->pledge = value;
        } else if (strcmp(arg, "--unveil") == 0) {
            if (o->unveil_count >= MAX_UNVEILS) {
                usage("too many --unveil entries");
                return -1;
            }
            char *colon = strrchr(value, ':');
            if (colon == NULL) {
                usage("--unveil expects PATH:PERMS");
                return -1;
            }
            *colon = '\0';
            o->unveils[o->unveil_count].path = value;
            o->unveils[o->unveil_count].perms = colon + 1;
            o->unveil_count++;
        } else {
            usage("unknown argument");
            return -1;
        }
    }
    usage("missing -- <command>");
    return -1;
}

static void print_plan(const struct options *o)
{
    printf("platform: %s\n", TRHA_PLATFORM);
    if (o->workspace) printf("workspace: %s\n", o->workspace);
    if (o->scratch) printf("scratch: %s\n", o->scratch);
    if (o->policy) printf("policy: %s\n", o->policy);
    if (o->network) printf("network: %s\n", o->network);
    if (o->pledge) printf("pledge: %s\n", o->pledge);
    for (int i = 0; i < o->unveil_count; i++) {
        printf("unveil: %s:%s\n", o->unveils[i].path, o->unveils[i].perms);
    }
    printf("command:");
    for (int i = 0; i < o->command_argc; i++) {
        printf(" %s", o->command[i]);
    }
    printf("\n");
}

#if defined(__FreeBSD__)
/*
 * Capsicum cannot express paths: it limits what a descriptor may do. So we
 * pre-open the writable roots, hand them a read/write rights mask, and only
 * then enter capability mode — after that, path lookups fail by construction.
 */
static int apply_freebsd(const struct options *o)
{
    cap_rights_t rights;
    cap_rights_init(&rights, CAP_READ, CAP_WRITE, CAP_LOOKUP, CAP_FSTAT, CAP_FCNTL);

    const char *dirs[2] = { o->workspace, o->scratch };
    for (int i = 0; i < 2; i++) {
        if (dirs[i] == NULL) continue;
        int fd = open(dirs[i], O_RDONLY | O_DIRECTORY);
        if (fd < 0) {
            fprintf(stderr, "trha-sandbox: open %s: %s\n", dirs[i], strerror(errno));
            return -1;
        }
        if (cap_rights_limit(fd, &rights) < 0) {
            fprintf(stderr, "trha-sandbox: cap_rights_limit %s: %s\n", dirs[i], strerror(errno));
            return -1;
        }
        /* Keep the fd open for the child: it is the only writable handle. */
    }
    if (cap_enter() < 0) {
        fprintf(stderr, "trha-sandbox: cap_enter: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}
#endif

#if defined(__OpenBSD__)
/*
 * unveil is per-path and must be locked before pledge. Defaults to the same
 * promise set the renderer emits so a hand-run launcher stays usable.
 */
static int apply_openbsd(const struct options *o)
{
    for (int i = 0; i < o->unveil_count; i++) {
        if (unveil(o->unveils[i].path, o->unveils[i].perms) == -1) {
            fprintf(stderr, "trha-sandbox: unveil %s: %s\n", o->unveils[i].path, strerror(errno));
            return -1;
        }
    }
    if (unveil(NULL, NULL) == -1) {
        fprintf(stderr, "trha-sandbox: unveil lock: %s\n", strerror(errno));
        return -1;
    }
    const char *promises = o->pledge ? o->pledge : "stdio rpath proc exec";
    if (pledge(promises, NULL) == -1) {
        fprintf(stderr, "trha-sandbox: pledge %s: %s\n", promises, strerror(errno));
        return -1;
    }
    return 0;
}
#endif

int main(int argc, char **argv)
{
    struct options o;
    if (parse_args(argc, argv, &o) != 0) {
        return 126;
    }
    if (o.dry_run) {
        print_plan(&o);
        return 0;
    }

#if !defined(__FreeBSD__) && !defined(__OpenBSD__)
    fprintf(stderr,
        "trha-sandbox: unsupported platform; this launcher only enforces on "
        "FreeBSD (capsicum) or OpenBSD (pledge/unveil)\n");
    return 126;
#else
    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "trha-sandbox: fork: %s\n", strerror(errno));
        return 126;
    }
    if (pid == 0) {
#if defined(__FreeBSD__)
        if (apply_freebsd(&o) != 0) _exit(126);
#else
        if (apply_openbsd(&o) != 0) _exit(126);
#endif
        execvp(o.command[0], o.command);
        fprintf(stderr, "trha-sandbox: exec %s: %s\n", o.command[0], strerror(errno));
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        fprintf(stderr, "trha-sandbox: waitpid: %s\n", strerror(errno));
        return 126;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 126;
#endif
}
