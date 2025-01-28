// for libesmglob.a to work you need to build it with -Doptimize=ReleaseFast
// ReleaseSmall may also work

#include <stdio.h>
#include "esmglob.h"

int
main(int argc, char *argv[])
{
	int res;
	Glob *g;

	res = esmglob("*", "hello");
	printf("should be 1: res = %d\n", res);
	res = esmglob("test", "pleasefail");
	printf("should be 0: res = %d\n", res);
	g = esmglob_compile("*");
	if (!g) {
		printf("error: g = null\n");
		return -1;
	}
	res = esmglob_compiled(g, "hello");
	printf("should be 1: res = %d\n", res);
	return 0;
}
