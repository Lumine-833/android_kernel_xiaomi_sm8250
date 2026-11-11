#ifndef __KSU_H_SUCOMPAT
#define __KSU_H_SUCOMPAT
#include <asm/ptrace.h>
#include <linux/types.h>
#include <linux/version.h>

extern bool ksu_su_compat_enabled;

/* SukiSU switches the sucompat hooks to struct filename ** when
 * SUSFS is on; that is only valid for 5.10+ VFS entry points.
 * 4.19 still passes const char __user * from fs/open.c and
 * fs/stat.c, so keep the __user implementation here. */
#if defined(CONFIG_KSU_SUSFS) && \
	(LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0))
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                 void *argv_user, void *envp_user,
                 int *flags);
#else
int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *__unused_flags);
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user, void *argv, void *__never_use_envp,
                               int *__never_use_flags);
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *__never_use_envp,
                                 int *__never_use_flags);
#endif

void ksu_sucompat_init(void);
void ksu_sucompat_exit(void);

#endif