#import <Foundation/Foundation.h>
#import "spawn.h"
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <dlfcn.h>
#include <rootless.h>
#include <sys/types.h>

// On roothide this binary lives inside the jbroot, i.e. under /private/var, which is mounted
// nosuid — the setuid bit is inert there and setuid(0) leaves us as mobile. Dopamine's own tooling
// asks jailbreakd for root instead, so fall back to that when the setuid route comes up short.
static void acquireRoot(void) {
	setuid(0);
	setgid(0);
	if (getuid() == 0) {
		return;
	}

	void *handle = dlopen(ROOT_PATH("/usr/lib/libjailbreak.dylib"), RTLD_NOW);
	if (!handle) {
		return;
	}

	int (*stealUcred)(uint64_t, uint64_t *) = dlsym(handle, "jbclient_root_steal_ucred");
	if (stealUcred) {
		uint64_t originalUcred = 0;
		stealUcred(0, &originalUcred);
	}
}

int main(int argc, char *argv[], char *envp[]) {
	// --check reports whether root can be had without actually rebooting anything.
	BOOL checkOnly = (argc > 1 && strcmp(argv[1], "--check") == 0);
	uid_t uidBefore = getuid();

	acquireRoot();

	if (checkOnly) {
		printf("uid before=%u after=%u -> %s\n", uidBefore, getuid(),
			getuid() == 0 ? "root acquired" : "FAILED to get root");
		exit(getuid() == 0 ? 0 : 1);
	}

	if (getuid() != 0) {
		exit(1);
	}

	pid_t pid;
    const char* args[] = {"launchctl", "reboot", "userspace", NULL};
    posix_spawn(&pid, ROOT_PATH("/usr/bin/launchctl"), NULL, NULL, (char* const*)args, NULL);
	exit(0);
}
