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

static void runUserspaceReboot(void) {
	pid_t pid;
	const char* args[] = {"launchctl", "reboot", "userspace", NULL};
	posix_spawn(&pid, ROOT_PATH("/usr/bin/launchctl"), NULL, NULL, (char* const*)args, NULL);
}

// Choicy decides whether a tweak loads as the process starts, so a running daemon keeps whatever it
// was launched with. Restarting these two is what makes a LetMeBlock toggle take effect; launchd
// brings them straight back.
static void restartMDNSResponder(void) {
	pid_t pid;
	const char* args[] = {"killall", "mDNSResponder", "mDNSResponderHelper", NULL};
	posix_spawn(&pid, ROOT_PATH("/usr/bin/killall"), NULL, NULL, (char* const*)args, NULL);
}

int main(int argc, char *argv[], char *envp[]) {
	// No argument keeps the behaviour this helper had when it was named userspace-reboot.
	const char *command = argc > 1 ? argv[1] : "userspace-reboot";

	// --check reports whether root can be had without touching anything.
	BOOL checkOnly = strcmp(command, "--check") == 0;
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

	if (strcmp(command, "userspace-reboot") == 0) {
		runUserspaceReboot();
	} else if (strcmp(command, "restart-mdns") == 0) {
		restartMDNSResponder();
	} else {
		fprintf(stderr, "usage: %s [userspace-reboot|restart-mdns|--check]\n", argv[0]);
		exit(2);
	}
	exit(0);
}
