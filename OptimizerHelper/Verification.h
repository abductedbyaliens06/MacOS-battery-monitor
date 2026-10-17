#pragma once
#include <sys/types.h>
/* Runs only a bounded disposable child, never a discovered user process. */
int BOVerifyCrossProcess(uid_t uid);
