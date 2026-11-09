// Feasibility spike: how fast can a child flood a pty while the reader
// renders a frame every 16.7 ms (R ms of pure CPU, no syscalls), parsing
// at P ns/byte?  Variants:
//   frame  : read() to EAGAIN only at each frame start (frame-driven drain)
//   defer  : multishot READ + buffer ring, ring in DEFER_TASKRUN|SINGLE_ISSUER,
//            completions handled as they arrive between frames
//   coop   : the same, ring in COOP_TASKRUN|TASKRUN_FLAG
//   sqpoll : the same, ring in SQPOLL
//   thread : a reader thread doing blocking read() into a queue
// Prints the bytes the consumer received per second.
//
// The evidence for decision OPLD1 of ../output-latency.md. Build against
// liburing and the kernel's uapi headers (nixpkgs: liburing, linuxHeaders):
//
//   gcc -O2 -o ingest ingest-spike.c -idirafter $LINUX_HEADERS/include \
//       -I$LIBURING_DEV/include -L$LIBURING/lib -luring -lutil -lpthread
//
// and run `NB=1 MB=32 ./ingest MODE RENDER_MS PARSE_NS`. `NB=1` makes the
// pty master non-blocking, which a multishot read needs (without it the read
// never completes and the run hangs); `MB` is the volume the child writes.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <pthread.h>
#include <pty.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static double R_MS = 4.0, P_NS = 2.0, FRAME_MS = 1000.0 / 60;
static size_t TOTAL = 64u << 20;
static void init_total(void) { if (getenv("MB")) TOTAL = (size_t)atoi(getenv("MB")) << 20; }
static volatile uint64_t sink;

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static void spin_until(uint64_t t) { while (now_ns() < t) sink++; }
static void parse(const char *p, size_t n)
{
    uint64_t end = now_ns() + (uint64_t)(n * P_NS);
    for (size_t i = 0; i < n; i += 64) sink += (unsigned char)p[i];
    spin_until(end);
}

// child: write TOTAL bytes of seq-like text, then report blocked ns via pipe
static void child(int slave, int report)
{
    char buf[4096];
    for (size_t i = 0; i < sizeof buf; i++) buf[i] = (i % 8 == 7) ? '\n' : '0' + i % 8;
    uint64_t blocked = 0, sent = 0;
    while (sent < TOTAL) {
        uint64_t t0 = now_ns();
        ssize_t n = write(slave, buf, sizeof buf);
        uint64_t dt = now_ns() - t0;
        if (dt > 20000) blocked += dt; // a write that waited for room
        if (n <= 0) break;
        sent += n;
    }
    write(report, &blocked, sizeof blocked);
    _exit(0);
}

static size_t got;
static int done;

static void on_bytes(const char *p, size_t n) { parse(p, n); got += n; }

// ---- frame-driven drain ----
static void run_frame(int master)
{
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    char buf[65536];
    uint64_t next = now_ns();
    while (!done) {
        for (;;) {
            ssize_t n = read(master, buf, sizeof buf);
            if (n > 0) { on_bytes(buf, n); continue; }
            if (n == 0 || errno != EAGAIN) done = 1;
            break;
        }
        spin_until(now_ns() + (uint64_t)(R_MS * 1e6));
        next += (uint64_t)(FRAME_MS * 1e6);
        uint64_t t = now_ns();
        if (next > t) { struct timespec d = {0, next - t}; nanosleep(&d, 0); }
        else next = t;
    }
}

// ---- multishot read into a provided buffer ring ----
enum { NBUF = 64, BUFSZ = 16384, BGID = 1 };
static void run_uring(int master, unsigned flags)
{
    struct io_uring ring;
    struct io_uring_params p = {0};
    p.flags = flags;
    if (flags & IORING_SETUP_SQPOLL) p.sq_thread_idle = 200;
    int r = io_uring_queue_init_params(64, &ring, &p);
    if (r < 0) { fprintf(stderr, "init: %s\n", strerror(-r)); exit(1); }
    int err;
    struct io_uring_buf_ring *br = io_uring_setup_buf_ring(&ring, NBUF, BGID, 0, &err);
    if (!br) { fprintf(stderr, "buf ring: %s\n", strerror(-err)); exit(1); }
    char *mem = malloc((size_t)NBUF * BUFSZ);
    for (int i = 0; i < NBUF; i++)
        io_uring_buf_ring_add(br, mem + (size_t)i * BUFSZ, BUFSZ, i, io_uring_buf_ring_mask(NBUF), i);
    io_uring_buf_ring_advance(br, NBUF);
    if (getenv("NB")) fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    int armed = 0;
    uint64_t next = now_ns() + (uint64_t)(FRAME_MS * 1e6);
    while (!done) {
        if (!armed) {
            struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
            io_uring_prep_read_multishot(sqe, master, 0, 0, BGID);
            armed = 1;
            io_uring_submit(&ring);
        }
        // between frames: wait for completions until the frame deadline
        uint64_t t = now_ns();
        if (t >= next) {
            spin_until(now_ns() + (uint64_t)(R_MS * 1e6));
            next += (uint64_t)(FRAME_MS * 1e6);
            if (next < now_ns()) next = now_ns();
            continue;
        }
        struct __kernel_timespec ts = {0, (long long)(next - t)};
        struct io_uring_cqe *cqe;
        r = io_uring_wait_cqe_timeout(&ring, &cqe, &ts);
        if (r == -ETIME || r == -EINTR) continue;
        if (r < 0) { fprintf(stderr, "wait: %s\n", strerror(-r)); exit(1); }
        unsigned head, seen = 0;
        io_uring_for_each_cqe(&ring, head, cqe) {
            seen++;
            if (cqe->res > 0) {
                int bid = cqe->flags >> IORING_CQE_BUFFER_SHIFT;
                on_bytes(mem + (size_t)bid * BUFSZ, cqe->res);
                io_uring_buf_ring_add(br, mem + (size_t)bid * BUFSZ, BUFSZ, bid, io_uring_buf_ring_mask(NBUF), 0);
                io_uring_buf_ring_advance(br, 1);
            } else if (cqe->res == 0 || (cqe->res < 0 && cqe->res != -ENOBUFS)) {
                done = 1;
            }
            if (!(cqe->flags & IORING_CQE_F_MORE)) armed = 0;
        }
        io_uring_cq_advance(&ring, seen);
    }
    io_uring_queue_exit(&ring);
}

// ---- reader thread ----
static char *q; static size_t qcap = 8u << 20;
static atomic_size_t qhead, qtail; // bytes written / consumed
static int master_fd;
static void *reader(void *arg)
{
    (void)arg;
    for (;;) {
        size_t h = atomic_load(&qhead), t = atomic_load(&qtail);
        size_t room = qcap - (h - t), off = h % qcap, chunk = qcap - off;
        if (room == 0) { struct timespec d = {0, 100000}; nanosleep(&d, 0); continue; }
        if (chunk > room) chunk = room;
        ssize_t n = read(master_fd, q + off, chunk);
        if (n <= 0) { done = 1; return 0; }
        atomic_store(&qhead, h + n);
    }
}
static void run_thread(int master)
{
    master_fd = master;
    q = malloc(qcap);
    pthread_t th;
    pthread_create(&th, 0, reader, 0);
    uint64_t next = now_ns() + (uint64_t)(FRAME_MS * 1e6);
    while (!done || atomic_load(&qhead) != atomic_load(&qtail)) {
        size_t h = atomic_load(&qhead), t = atomic_load(&qtail);
        if (h != t) {
            size_t off = t % qcap, n = h - t;
            if (n > qcap - off) n = qcap - off;
            on_bytes(q + off, n);
            atomic_store(&qtail, t + n);
        } else {
            struct timespec d = {0, 50000}; nanosleep(&d, 0);
        }
        if (now_ns() >= next) {
            spin_until(now_ns() + (uint64_t)(R_MS * 1e6));
            next += (uint64_t)(FRAME_MS * 1e6);
        }
    }
    pthread_join(th, 0);
}

int main(int argc, char **argv)
{
    init_total();
    const char *mode = argc > 1 ? argv[1] : "frame";
    if (argc > 2) R_MS = atof(argv[2]);
    if (argc > 3) P_NS = atof(argv[3]);
    int master, slave;
    if (openpty(&master, &slave, 0, 0, 0) < 0) { perror("openpty"); return 1; }
    int rep[2];
    pipe(rep);
    uint64_t t0 = now_ns();
    pid_t pid = fork();
    if (pid == 0) { close(master); close(rep[0]); child(slave, rep[1]); }
    close(slave); close(rep[1]);
    if (!strcmp(mode, "frame")) run_frame(master);
    else if (!strcmp(mode, "defer")) run_uring(master, IORING_SETUP_DEFER_TASKRUN | IORING_SETUP_SINGLE_ISSUER);
    else if (!strcmp(mode, "coop")) run_uring(master, IORING_SETUP_COOP_TASKRUN | IORING_SETUP_TASKRUN_FLAG);
    else if (!strcmp(mode, "sqpoll")) run_uring(master, IORING_SETUP_SQPOLL);
    else if (!strcmp(mode, "thread")) run_thread(master);
    double secs = (now_ns() - t0) / 1e9;
    uint64_t blocked = 0;
    read(rep[0], &blocked, sizeof blocked);
    waitpid(pid, 0, 0);
    printf("%-7s render %.1f ms/frame, parse %.1f ns/B: %6.1f MB/s, %zu MiB in %.2f s\n",
        mode, R_MS, P_NS, got / secs / 1e6, got >> 20, secs);
    return 0;
}
