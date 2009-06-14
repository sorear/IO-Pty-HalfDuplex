#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <string.h>

int
iphd_sysctl_is_waiting(int pid)
{
    struct kinfo_proc kip;
    size_t kipsz = sizeof(kip);
    int addr[4];
    int err;

    addr[0] = CTL_KERN;
    addr[1] = KERN_PROC;
    addr[2] = KERN_PROC_PID;
    addr[3] = pid;

    err = sysctl(addr, 4, &kip, &kipsz, NULL, 0);

    if (err < 0) {
        /* can happen due to races, so ignore XXX */
        return 0;
    }

    return kip.ki_stat == 'S' && !strcmp(kip.ki_wmesg, "ttyin");
}
