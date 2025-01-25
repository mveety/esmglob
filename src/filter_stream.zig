const std = @import("std");
const builtin = @import("builtin");
const glob = @import("glob.zig");
const matching = @import("matching.zig");

fn readline(reader: anytype, buf: []u8) !?[]const u8 {
    const line = try reader.readUntilDelimiterOrEof(buf, '\n') orelse return null;
    if (builtin.os.tag == .windows) {
        return std.mem.trimRight(u8, line, '\r');
    }
    return line;
}

pub fn filter_stream(
    writer: anytype,
    g: *glob.Glob,
    reader: anytype,
    buf: []u8,
    mprefix: ?[]const u8,
    number: bool,
    comp_match: bool,
    comp_filter: bool,
) !bool {
    var i: usize = 1;
    var found = false;

    while (try readline(reader, buf)) |line| : (i += 1) {
        if (matching.match(g, line, comp_match, comp_filter)) { // was false true
            if (number) {
                if (mprefix) |prefix| {
                    try writer.print("{s}:{d}: ", .{ prefix, i });
                } else {
                    try writer.print("{d}: ", .{i});
                }
            } else {
                if (mprefix) |prefix| try writer.print("{s}: ", .{prefix});
            }
            try writer.print("{s}\n", .{line});
            if (!found) found = true;
        }
    }
    return found;
}

pub fn match_stream(
    g: *glob.Glob,
    reader: anytype,
    buf: []u8,
    comp_match: bool,
    comp_filter: bool,
) !bool {
    while (try readline(reader, buf)) |line| {
        if (matching.match(g, line, comp_match, comp_filter)) return true;
    }
    return false;
}
