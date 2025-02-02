const std = @import("std");
pub usingnamespace @import("glob.zig");
pub usingnamespace @import("query.zig");
const matching = @import("matching.zig");
const glob = @import("glob.zig");

pub const cglob = extern struct {
    g: *glob.Glob,
};

pub export fn esmglob(cstrpattern: [*c]const u8, cstring: [*c]const u8) i32 {
    var globarena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer globarena.deinit();
    var globalloc = globarena.allocator();
    const strpattern = std.mem.span(cstrpattern);
    const string = std.mem.span(cstring);

    const pattern = glob.Glob.new(&globalloc, strpattern) catch {
        return -1;
    };
    if (matching.match(pattern, string, true, true)) return 1 else return 0;
}

pub export fn esmglob_compile(cstrpattern: [*c]const u8) ?*cglob {
    const allocator = @constCast(&std.heap.c_allocator);
    const strpattern = std.mem.span(cstrpattern);
    const cg = allocator.create(cglob) catch return null;
    cg.g = glob.Glob.new(allocator, strpattern) catch return null;
    return cg;
}

pub export fn esmglob_free(pattern: *cglob) void {
    pattern.g.destroy();
    std.heap.c_allocator.destroy(pattern);
}

pub export fn esmglob_compiled(pattern: cglob, cstring: [*c]const u8) i32 {
    const string = std.mem.span(cstring);
    if (matching.match(pattern.g, string, true, true)) return 1 else return 0;
}
