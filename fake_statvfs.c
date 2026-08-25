#define _GNU_SOURCE
#include <sys/vfs.h>
#include <sys/statfs.h>
#include <dlfcn.h>
#include <stdint.h>

/*
 * fake_statvfs.c — LD_PRELOAD shim for Wine/Fusion 360
 *
 * Fusion 360 refuses to install or launch if it detects < 50 GB of free disk
 * space. Wine's ntdll.so uses fstatfs() (not statvfs()) to query disk space,
 * so the standard Wine "fake_drive_c" workaround does not help here.
 *
 * This shim intercepts both fstatfs() and statfs() and reports a large virtual
 * disk (~763 GB total, ~572 GB free) so Fusion 360's pre-check always passes.
 * All other filesystem metadata is left unchanged.
 *
 * Build:
 *   gcc -shared -fPIC -o fake_statvfs.so fake_statvfs.c -ldl
 *
 * Use:
 *   Set LD_PRELOAD=/path/to/fake_statvfs.so in your Bottles bottle environment
 *   variables. The path must be on the host filesystem, NOT inside drive_c.
 */

static void spoof(struct statfs *buf) {
    if (buf) {
        buf->f_blocks = (fsblkcnt_t)200000000ULL;  /* ~763 GB total */
        buf->f_bfree  = (fsblkcnt_t)150000000ULL;  /* ~572 GB free  */
        buf->f_bavail = (fsblkcnt_t)150000000ULL;  /* ~572 GB avail */
    }
}

int fstatfs(int fd, struct statfs *buf) {
    static int (*real_fstatfs)(int, struct statfs *) = NULL;
    if (!real_fstatfs) real_fstatfs = dlsym(RTLD_NEXT, "fstatfs");
    int ret = real_fstatfs(fd, buf);
    if (ret == 0) spoof(buf);
    return ret;
}

int statfs(const char *path, struct statfs *buf) {
    static int (*real_statfs)(const char *, struct statfs *) = NULL;
    if (!real_statfs) real_statfs = dlsym(RTLD_NEXT, "statfs");
    int ret = real_statfs(path, buf);
    if (ret == 0) spoof(buf);
    return ret;
}
