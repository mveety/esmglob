const std = @import("std");

pub const Operation = enum {
    const Self = @This();
    match_stdin, // esmglob [-n] [pattern]
    match_args, // esmglob [pattern] [strings...]
    match_files, // esmglob [-n] -f [pattern] [files...]
    match_directory, // esmglob -d [pattern] [dir]
    search_files, // esmglob [-n] -s [pattern] [files...]
    usage, // anything else?
    help, // just like usage?
    version, // version.

    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .match_stdin => "match_stdin",
            .match_args => "match_args",
            .match_files => "match_files",
            .match_directory => "match_directory",
            .search_files => "search_files",
            .usage => "usage",
            .help => "help",
            .version => "version",
        };
    }
};

pub const ArgsOpt = struct {
    const Self = @This();
    const ArgsList = std.ArrayList([]const u8);

    optype: Operation = .usage,
    print_source: bool = false,
    print_number: bool = false,
    complete_match: bool = true,
    complete_filter: bool = true,
    silent: bool = false,
    debug: bool = false,
    tree: bool = false,
    include_hidden: bool = false,
    insert_newlines: bool = false,
    argerr: u8 = 0,
    argv0: []const u8 = undefined,
    pattern: []const u8 = undefined,
    things: ?[][]const u8 = null,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        allocator.free(self.argv0);
        if (self.pattern.len > 0) allocator.free(self.pattern);
        if (self.things) |things| {
            if (things.len > 0) {
                for (things) |thing| {
                    allocator.free(thing);
                }
                allocator.free(things);
            }
        }
        allocator.destroy(self);
    }

    pub fn toString(self: *Self, allocator: *std.mem.Allocator) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(allocator.*);
        defer arena.deinit();
        const aa = arena.allocator();
        var start = true;
        var res = try std.fmt.allocPrint(aa, "{*}{{optype = {s}", .{ self, self.optype.toString() });
        res = try std.fmt.allocPrint(aa, "{s}, print_source = {}", .{ res, self.print_source });
        res = try std.fmt.allocPrint(aa, "{s}, print_number = {}", .{ res, self.print_number });
        res = try std.fmt.allocPrint(aa, "{s}, silent = {}", .{ res, self.silent });
        res = try std.fmt.allocPrint(aa, "{s}, tree = {}", .{ res, self.tree });
        res = try std.fmt.allocPrint(aa, "{s}, include_hidden = {}", .{ res, self.include_hidden });
        res = try std.fmt.allocPrint(aa, "{s}, insert_newlines = {}", .{ res, self.insert_newlines });
        res = try std.fmt.allocPrint(aa, "{s}, argv0 = \"{s}\"", .{ res, self.argv0 });
        res = try std.fmt.allocPrint(aa, "{s}, complete_match = {}", .{ res, self.complete_match });
        res = try std.fmt.allocPrint(aa, "{s}, complete_filter = {}", .{ res, self.complete_filter });
        res = try std.fmt.allocPrint(aa, "{s}, pattern = \"{s}\"", .{ res, self.pattern });
        if (self.things) |things| {
            res = try std.fmt.allocPrint(aa, "{s}, things = {{", .{res});
            for (things) |thing| {
                if (start) {
                    res = try std.fmt.allocPrint(aa, "{s}\"{s}\"", .{ res, thing });
                    start = false;
                } else {
                    res = try std.fmt.allocPrint(aa, "{s}, \"{s}\"", .{ res, thing });
                }
            }
            res = try std.fmt.allocPrint(aa, "{s}}}", .{res});
        }
        res = try std.fmt.allocPrint(aa, "{s}}}", .{res});
        return allocator.dupe(u8, res);
    }

    pub fn parse(allocator: *std.mem.Allocator, argsiter: *std.process.ArgIterator) !*Self {
        const opts = try allocator.create(Self);
        opts.* = .{ .optype = .usage };
        errdefer allocator.destroy(opts);

        if (argsiter.next()) |argv0| {
            opts.argv0 = try allocator.dupe(u8, argv0);
            errdefer allocator.free(opts.argv0);
        } else {
            return error.Arguments;
        }
        while (argsiter.next()) |arg| {
            if (arg[0] == '-') {
                for (arg[1..]) |c| {
                    switch (c) {
                        'v' => opts.optype = .version,
                        's' => opts.optype = .search_files,
                        'f' => opts.optype = .match_files,
                        'd' => opts.optype = .match_directory,
                        'D' => opts.debug = true,
                        'n' => {
                            opts.print_number = true;
                            opts.print_source = true;
                            opts.insert_newlines = true;
                        },
                        'l' => opts.insert_newlines = true,
                        't' => opts.tree = true,
                        'H' => opts.include_hidden = true,
                        'N' => opts.print_number = true,
                        'S' => opts.print_source = true,
                        'F' => opts.complete_filter = false,
                        'M' => opts.complete_match = false,
                        'q' => opts.silent = true,
                        'h' => {
                            opts.optype = .help;
                            return opts;
                        },
                        else => {
                            opts.optype = .usage;
                            opts.argerr = c;
                            return opts;
                        },
                    }
                }
            } else {
                if (opts.optype == .usage) opts.optype = .match_stdin;
                opts.pattern = try allocator.dupe(u8, arg);
                errdefer allocator.free(opts.pattern);
                break;
            }
        }
        var argslist = std.ArrayList([]const u8).init(allocator.*);
        var haselems = false;
        while (argsiter.next()) |arg| {
            const data = try allocator.dupe(u8, arg);
            errdefer allocator.free(data);
            try argslist.append(data);
            haselems = true;
        }
        if (haselems) {
            opts.things = try argslist.toOwnedSlice();
            opts.optype = switch (opts.optype) {
                else => .match_args,
                .search_files, .match_files, .match_directory => opts.optype,
            };
        }
        return opts;
    }
};
