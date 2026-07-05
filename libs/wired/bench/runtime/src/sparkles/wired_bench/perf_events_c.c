/*
 * ImportC-compiled helper around perf_event_open(2) for the wired runtime
 * bench: one hardware counter group (cycles leader) + the page-fault
 * software event, read atomically with PERF_FORMAT_GROUP and scaled by
 * time_running/time_enabled when the kernel multiplexes.
 *
 * Deliberately includes only <linux/perf_event.h> (kernel UAPI — no glibc
 * fortify wrappers, which have broken ImportC before) and declares the few
 * libc entry points by hand. Compiles to an empty module off Linux.
 */
#ifdef __linux__

/* ImportC cannot represent __int128; <linux/types.h> only typedefs
 * __s128/__u128 under this guard, and nothing perf_event.h uses needs
 * them. */
#undef __SIZEOF_INT128__

#include <linux/perf_event.h>

#include <stddef.h>
#include <stdint.h>

extern long syscall(long, ...);
extern int ioctl(int, unsigned long, ...);
extern long read(int, void *, unsigned long);
extern int close(int);

/* perf_event_open has had a stable syscall number since Linux 2.6.32. */
#if defined(__x86_64__)
#define JB_SYS_perf_event_open 298
#elif defined(__aarch64__)
#define JB_SYS_perf_event_open 241
#else
#error "wired-bench perf: unsupported architecture"
#endif

enum { jb_perf_nevents = 7 };

/* Order is the ABI with the D side (perf.d): cycles, instructions,
 * branches, branch-misses, cache-references, cache-misses, page-faults. */
static const struct {
    uint32_t type;
    uint64_t config;
} jb_events[jb_perf_nevents] = {
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_INSTRUCTIONS },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_BRANCH_MISSES },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_REFERENCES },
    { PERF_TYPE_HARDWARE, PERF_COUNT_HW_CACHE_MISSES },
    { PERF_TYPE_SOFTWARE, PERF_COUNT_SW_PAGE_FAULTS },
};

typedef struct jb_perf_group {
    int fds[jb_perf_nevents]; /* -1 = event unavailable on this machine */
    int user_only;            /* 1 = kernel-side counting was refused    */
    int n_open;
} jb_perf_group;

static int jb_perf_try_open(jb_perf_group *g, int exclude_kernel, int with_cache)
{
    g->n_open = 0;
    g->user_only = exclude_kernel;
    int leader = -1;
    for (int i = 0; i < jb_perf_nevents; i++) {
        /* The LLC pair pushes the group past the free PMCs when the NMI
         * watchdog holds one; the caller drops it when calibration shows
         * multiplexing (values would be rotation-scaled estimates). */
        if (!with_cache && jb_events[i].type == PERF_TYPE_HARDWARE
            && (jb_events[i].config == PERF_COUNT_HW_CACHE_REFERENCES
                || jb_events[i].config == PERF_COUNT_HW_CACHE_MISSES)) {
            g->fds[i] = -1;
            continue;
        }
        struct perf_event_attr attr = { 0 };
        attr.size = sizeof(attr);
        attr.type = jb_events[i].type;
        attr.config = jb_events[i].config;
        attr.disabled = (leader == -1);
        attr.exclude_kernel = exclude_kernel;
        attr.exclude_hv = 1;
        if (leader == -1)
            attr.read_format = PERF_FORMAT_GROUP
                | PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;

        long fd = syscall(JB_SYS_perf_event_open, &attr, /*pid=*/0,
            /*cpu=*/-1, /*group_fd=*/leader, /*flags=*/0UL);
        g->fds[i] = (int) fd;
        if (fd >= 0) {
            g->n_open++;
            if (leader == -1)
                leader = (int) fd;
        } else if (leader == -1) {
            return -1; /* no leader — this permission level is a bust */
        }
    }
    return 0;
}

/* Opens the counter group (with or without the LLC pair); kernel+user
 * first, user-only as the fallback. Returns 0 when at least the cycles
 * leader opened, -1 when perf is unavailable (perf_event_paranoid,
 * seccomp, missing PMU, ...). */
int jb_perf_open(jb_perf_group *g, int with_cache)
{
    for (int i = 0; i < jb_perf_nevents; i++)
        g->fds[i] = -1;
    if (jb_perf_try_open(g, 0, with_cache) == 0)
        return 0;
    jb_perf_close(g);
    if (jb_perf_try_open(g, 1, with_cache) == 0)
        return 0;
    jb_perf_close(g);
    return -1;
}

void jb_perf_close(jb_perf_group *g)
{
    for (int i = 0; i < jb_perf_nevents; i++) {
        if (g->fds[i] >= 0)
            close(g->fds[i]);
        g->fds[i] = -1;
    }
    g->n_open = 0;
}

int jb_perf_reset(const jb_perf_group *g)
{
    int rc = 0;
    for (int i = 0; i < jb_perf_nevents; i++)
        if (g->fds[i] >= 0 && ioctl(g->fds[i], PERF_EVENT_IOC_RESET, 0) != 0)
            rc = -1;
    return rc;
}

int jb_perf_enable(const jb_perf_group *g)
{
    return ioctl(g->fds[0], PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
}

int jb_perf_disable(const jb_perf_group *g)
{
    return ioctl(g->fds[0], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
}

/* Reads the whole group atomically. out[jb_perf_nevents] receives the
 * multiplex-scaled totals in jb_events order, UINT64_MAX marking events
 * that could not be opened; *scale receives time_running/time_enabled
 * (1.0 = the group was never multiplexed off the PMU). Returns 0/-1. */
int jb_perf_read_counters(const jb_perf_group *g, uint64_t *out, double *scale)
{
    /* struct read_format { u64 nr, time_enabled, time_running, values[]; } */
    uint64_t buf[3 + jb_perf_nevents];
    long want = (long) sizeof(uint64_t) * (3 + (long) g->n_open);
    if (read(g->fds[0], buf, sizeof(buf)) < want)
        return -1;

    double ratio = 1.0;
    if (buf[2] > 0 && buf[1] > 0 && buf[2] < buf[1])
        ratio = (double) buf[1] / (double) buf[2];
    *scale = buf[1] > 0 ? (double) buf[2] / (double) buf[1] : 1.0;

    int slot = 0;
    for (int i = 0; i < jb_perf_nevents; i++) {
        if (g->fds[i] < 0) {
            out[i] = UINT64_MAX;
            continue;
        }
        double scaled = (double) buf[3 + slot] * ratio;
        out[i] = (uint64_t) scaled;
        slot++;
    }
    return 0;
}

#endif /* __linux__ */
