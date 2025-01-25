const std = @import("std");
const do_match = @import("do_match.zig");
const glob = @import("glob.zig");

pub fn match(
    g: *glob.Glob,
    s: []const u8,
    comp_match: bool,
    comp_filter: bool,
) bool {
    if (g.match_pattern) |mp| {
        const matchlen = do_match.do_match(s, mp, null) catch return false;
        if (matchlen < s.len and comp_match) return false;
    }
    if (g.filter_pattern) |fp| {
        const filterlen = do_match.do_match(s, fp, null) catch return true;
        if (filterlen < s.len and comp_filter) return true;
        return false;
    }
    return true;
}

pub fn match_string(
    allocator: *std.mem.Allocator,
    pattern: []const u8,
    string: []const u8,
    comp_match: bool,
    comp_filter: bool,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator.*);
    defer arena.deinit();
    var aa = arena.allocator();

    const compglob = try glob.Glob.new(&aa, pattern);
    return match(compglob, string, comp_match, comp_filter);
}

pub fn match_only(g: *glob.Glob, s: []const u8) !usize {
    if (g.match_pattern) |mp| {
        return do_match.do_match(s, mp, null);
    }
    return s.len;
}

pub fn filter_only(g: *glob.Glob, s: []const u8) !usize {
    if (g.filter_pattern) |fp| {
        return do_match.do_match(s, fp, null);
    }
    return 0;
}
