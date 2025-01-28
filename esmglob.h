#ifndef esmglob_h
#define esmglob_h

// you should be including this anyway
#include <stdint.h>

// the glob struct is opaque to the user. it's field is all zig
typedef struct {
	void *g;
} Glob;

// pattern, string to match
// return -1 on error, 0 on no match, 1 on match
extern int32_t esmglob(const char*, const char*);
// pattern, returns glob, null on error
extern Glob *esmglob_compile(const char*);
// compiled glob, pattern, return the same as esmglob
extern int32_t esmglob_compiled(Glob*, const char*);
// free an esmglob, no return
extern void esmglob_free(Glob*);

#endif

