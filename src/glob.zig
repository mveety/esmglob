const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const patterns = @import("patterns.zig");
const parser = @import("parser.zig");

pub const CompilerError = error{
    EmptyGlob,
} || parser.ParseError || patterns.PatternError;

pub const Glob = struct {
    const Self = @This();
    allocator: *std.mem.Allocator,
    matchstr: ?[]const u8,
    filterstr: ?[]const u8,
    match_pattern: ?*patterns.Pattern,
    filter_pattern: ?*patterns.Pattern,

    pub fn make(allocator: *std.mem.Allocator, glob: []const u8) !*Glob {
        if (glob.len < 1) return CompilerError.EmptyGlob;

        const newglob = try allocator.create(Self);
        newglob.* = .{
            .allocator = allocator,
            .matchstr = null,
            .filterstr = null,
            .match_pattern = null,
            .filter_pattern = null,
        };
        errdefer allocator.destroy(newglob);

        const split_point = find_split_point(glob) catch {
            newglob.matchstr = try allocator.dupe(u8, glob);
            return newglob;
        };

        if (split_point == (glob.len - 1)) {
            newglob.matchstr = try allocator.dupe(u8, glob[0..split_point]);
            return newglob;
        }
        if (split_point == 0) {
            if (glob.len < 2) return CompilerError.EmptyGlob;
            newglob.filterstr = try allocator.dupe(u8, glob[1..]);
            return newglob;
        }
        newglob.matchstr = try allocator.dupe(u8, glob[0..split_point]);
        newglob.filterstr = try allocator.dupe(u8, glob[(split_point + 1)..]);
        return newglob;
    }

    pub fn destroy(self: *Self) void {
        const allocator = self.allocator;

        if (self.matchstr) |sms| allocator.free(sms);
        if (self.filterstr) |sfs| allocator.free(sfs);
        if (self.match_pattern) |mp| mp.destroy(allocator);
        if (self.filter_pattern) |fp| fp.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn compile(self: *Self) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator.*);
        defer arena.deinit();
        var aa = arena.allocator();

        if (self.matchstr) |sms| {
            const mtoks = try tokenizer.tokenize_string(&aa, sms);
            const mpattern = try parser.parse_tokens(&aa, mtoks, null) orelse
                return CompilerError.EmptyPattern;
            self.match_pattern = try mpattern.copy(self.allocator);
        }
        if (self.filterstr) |sfs| {
            const ftoks = try tokenizer.tokenize_string(&aa, sfs);
            const fpattern = try parser.parse_tokens(&aa, ftoks, null) orelse
                return CompilerError.EmptyPattern;
            self.filter_pattern = try fpattern.copy(self.allocator);
        }
    }

    pub fn new(allocator: *std.mem.Allocator, s: []const u8) !*Self {
        const newglob = try Self.make(allocator, s);
        try newglob.compile();
        return newglob;
    }

    pub fn toString(self: *Self, allocator: *std.mem.Allocator) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator.*);
        defer arena.deinit();
        var aa = arena.allocator();
        const matchstring = if (self.match_pattern) |mp| try mp.toString(&aa) else "";
        const filterstring = if (self.filter_pattern) |fp| try fp.toString(&aa) else "";

        var res = if (self.match_pattern) |_|
            try std.fmt.allocPrint(aa, "{s}", .{matchstring})
        else
            "*";
        res = if (self.filter_pattern) |_|
            try std.fmt.allocPrint(aa, "{s}!{s}", .{ res, filterstring })
        else
            res;
        return allocator.dupe(u8, res);
    }
};

fn find_split_point(s: []const u8) error{NoExpPoint}!usize {
    var i: usize = 0;
    var escape = false;

    while (i < s.len) : (i += 1) {
        if (escape) {
            escape = false;
            continue;
        }
        if (s[i] == '\\') {
            escape = true;
            continue;
        }
        if (s[i] == '!') return i;
    }
    return error.NoExpPoint;
}

test "glob_compile simple" {
    var allocator = std.heap.page_allocator;
    const test_input = "helloworld";
    const test_output = "helloworld";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}

test "glob_compile match and filter" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello!world";
    const test_output = "hello!world";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}

test "glob_compile only filter" {
    var allocator = std.heap.page_allocator;
    const test_input = "!world";
    const test_output = "*!world";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}

test "glob_compile errant exclaimation point" {
    var allocator = std.heap.page_allocator;
    const test_input = "helloworld!";
    const test_output = "helloworld";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}

test "glob_compile escaped exclaimation point" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello\\! this is a test!world";
    // escaping is only for the tokenizer's benefit so it's
    // lost when converting a glob to a string
    const test_output = "hello! this is a test!world";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}

test "glob_compile trailing match exclaimation point" {
    var allocator = std.heap.page_allocator;
    const test_input = "hel*\\!a!*tia";
    const test_output = "hel*!a!*tia";

    const newglob = try Glob.new(&allocator, test_input);
    const res = try newglob.toString(&allocator);
    try std.testing.expect(std.mem.eql(u8, res, test_output));
}
