const std = @import("std");
const args = @import("args.zig");
const glob = @import("glob.zig");
const query = @import("query.zig");
const filter_stream = @import("filter_stream.zig");
const file_query = @import("file_query.zig");
const direct_query = @import("direct_query.zig");

const ESMGLOB_VERSION = "git-main";

fn usage(argv0: []const u8, out: anytype, helptext: bool) !noreturn {
    const help_text =
        \\ Modes:
        \\ match against stdin: esmglob pattern
        \\     returns matches on stdout
        \\ match against arguments: esmglob pattern args to match against
        \\     return matches on stdout
        \\ match against files: esmglob -s pattern files...
        \\     returns files that contain a match
        \\ match against file contents: esmglob -f pattern files...
        \\     returns file contents that matches
        \\ match against the current directory: esmglob -d pattern
        \\     returns a list of matching files
        \\ match against any directory: esmglob -d pattern directory
        \\
        \\ Options:
        \\  -q -- silent output
        \\  -n -- print line number and data source
        \\  -l -- insert newlines in file lists
        \\  -t -- descend directory tree
        \\  -H -- include hidden files
        \\  -N -- print line numbers
        \\  -S -- print data source
        \\  -M -- add implicit * to the end of matches
        \\  -F -- add implicit * to the end of filters
    ;
    try out.print("{s} [-qnltHSMF] [-f|-s|-d] pattern [files, directories, or strings]\n", .{argv0});
    if (helptext) {
        try out.print("{s}\n", .{help_text});
    }
    if (helptext)
        std.process.exit(0);
    std.process.exit(128);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .retain_metadata = true }){};
    const root_allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var retval: u8 = 0;

    // set up standard io. buffered i/o on stdin
    // straight io on stdout and stderr
    const stdin_file = std.io.getStdIn().reader();
    var stdin_br = std.io.bufferedReader(stdin_file);
    const stdout = std.io.getStdOut().writer();
    const stdin = stdin_br.reader();
    const stderr = std.io.getStdErr().writer();

    var args_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer args_arena.deinit();
    var args_allocator = args_arena.allocator();
    var argsiter = try std.process.ArgIterator.initWithAllocator(args_allocator);
    const opts = try args.ArgsOpt.parse(&args_allocator, &argsiter);
    if (opts.debug) {
        const opts_str = try opts.toString(&args_allocator);
        stderr.print("debug: opts = {s}\n", .{opts_str}) catch @panic("stderr");
    }

    switch (opts.optype) {
        .usage => {
            if (opts.argerr != 0)
                try stderr.print("error: unknown argument: -{c}\n", .{opts.argerr});
            try usage(opts.argv0, stderr, false);
        },
        .help => try usage(opts.argv0, stdout, true),
        .version => {
            stdout.print("esmglob {s}\n", .{ESMGLOB_VERSION}) catch |err| {
                stderr.print("error: {!}\n", .{err}) catch @panic("stderr");
                return err;
            };
        },

        .match_stdin => {
            retval = 1;
            var found = false;
            var match_arena = std.heap.ArenaAllocator.init(root_allocator);
            defer match_arena.deinit();
            var match_allocator = match_arena.allocator();
            const buf = try match_allocator.alloc(u8, 32*1024);
            const g = glob.Glob.new(&match_allocator, opts.pattern) catch |err| {
                try stderr.print("esmglob: error: {!}\n", .{err});
                std.process.exit(255);
            };
            if (opts.debug) {
                const globstring = try g.toString(&match_allocator);
                try stderr.print("debug: {*} = {s}\n", .{ g, globstring });
            }
            const mprefix: ?[]const u8 = if (opts.print_source) "stdin" else null;
            if (opts.silent) {
                found = try filter_stream.match_stream(
                    g,
                    stdin,
                    buf,
                    opts.complete_match,
                    opts.complete_filter,
                );
            } else {
                found = try filter_stream.filter_stream(
                    stdout,
                    g,
                    stdin,
                    buf,
                    mprefix,
                    opts.print_number,
                    opts.complete_match,
                    opts.complete_filter,
                );
            }
            if (found and retval == 1) retval = 0;
        },

        .match_args => {
            var query_arena = std.heap.ArenaAllocator.init(root_allocator);
            defer query_arena.deinit();
            var query_allocator = query_arena.allocator();
            const q = query.Query.new(&query_allocator, opts.pattern) catch |err| {
                try stderr.print("esmglob: error: {!}\n", .{err});
                std.process.exit(255);
            };
            const things = opts.things orelse return error.MissingMatchArgs;
            if (opts.debug) {
                const globstring = try q.pattern.toString(&query_allocator);
                try stderr.print("debug: {*} = {s}\n", .{ q.pattern, globstring });
            }
            q.configure(opts.complete_match, opts.complete_filter);
            for (things) |thing| try q.addData(thing, null);
            try q.run();
            if (q.hasResults()) {
                const results = try q.resultArray(&query_allocator);
                for (results, 1..) |result, line| {
                    if (opts.print_number) {
                        if (!opts.silent) try stdout.print("{d}: {s}\n", .{ line, result.string });
                    } else {
                        if (!opts.silent) try stdout.print("{s}\n", .{result.string});
                    }
                }
            } else {
                retval = 1;
            }
        },

        .search_files => {
            var query_arena = std.heap.ArenaAllocator.init(root_allocator);
            defer query_arena.deinit();
            var query_allocator = query_arena.allocator();
            const q = file_query.FileQuery.new(&query_allocator, opts.pattern) catch |err| {
                try stderr.print("esmglob: error: {!}\n", .{err});
                std.process.exit(255);
            };
            const things = opts.things orelse return error.MissingMatchArgs;
            q.configure(opts.complete_match, opts.complete_filter);
            if (opts.debug) {
                const globstring = try q.pattern.toString(&query_allocator);
                try stderr.print("debug: {*} = {s}\n", .{ q.pattern, globstring });
            }
            for (things) |thing| try q.addFile(thing);
            try q.run();
            if (q.hasResults()) {
                const results = try q.resultArray(&query_allocator);
                for (results, 1..) |result, line| {
                    if (opts.print_number) {
                        if (!opts.silent)
                            try stdout.print("{d}: {s}\n", .{ line, result });
                    } else {
                        if (!opts.silent)
                            try stdout.print("{s}", .{result});
                        if (opts.insert_newlines) {
                            try stdout.print("\n", .{});
                        } else {
                            try stdout.print(" ", .{});
                        }
                    }
                }
            } else {
                retval = 1;
            }
        },

        .match_files => {
            retval = 1;
            var found = false;
            var search_arena = std.heap.ArenaAllocator.init(root_allocator);
            defer search_arena.deinit();
            var search_allocator = search_arena.allocator();
            const files = opts.things orelse return error.MissingMatchArgs;
            const buf = try search_allocator.alloc(u8, 32*1024);
            const g = glob.Glob.new(&search_allocator, opts.pattern) catch |err| {
                try stderr.print("esmglob: error: {!}\n", .{err});
                std.process.exit(255);
            };
            if (opts.debug) {
                const globstring = try g.toString(&search_allocator);
                try stderr.print("debug: {*} = {s}\n", .{ g, globstring });
            }
            for (files) |file| {
                if (opts.debug) try stderr.print("debug: reading file {s}\n", .{file});
                const mp = if (opts.print_source) file else null;
                const fd = std.fs.cwd().openFile(file, .{}) catch |err| {
                    try stderr.print("esmglob: {s}: {!}\n", .{ file, err });
                    continue;
                };
                defer fd.close();
                const reader = fd.reader();
                if (opts.silent) {
                    found = try filter_stream.match_stream(
                        g,
                        reader,
                        buf,
                        opts.complete_match,
                        opts.complete_filter,
                    );
                } else {
                    found = try filter_stream.filter_stream(
                        stdout,
                        g,
                        reader,
                        buf,
                        mp,
                        opts.print_number,
                        opts.complete_match,
                        opts.complete_filter,
                    );
                }
                if (found and retval == 1) retval = 0;
            }
        },

        .match_directory => {
            retval = 1;
            var dir_arena = std.heap.ArenaAllocator.init(root_allocator);
            defer dir_arena.deinit();
            var dir_allocator = dir_arena.allocator();
            var mpath: ?[]const u8 = null;
            if (opts.things) |things| {
                const tmp = things[0];
                mpath = if (tmp[tmp.len - 1] == '/') tmp[0..(tmp.len - 1)] else tmp;
            }
            const dirquery = direct_query.DirQuery.new(&dir_allocator, opts.pattern, mpath) catch |err| {
                try stderr.print("esmglob: error: {!}\n", .{err});
                std.process.exit(255);
            };
            if (opts.debug) {
                const globstring = try dirquery.pattern.toString(&dir_allocator);
                try stderr.print("debug: {*} = {s}\n", .{ dirquery.pattern, globstring });
            }
            dirquery.configure(opts.complete_match, opts.complete_filter, opts.tree, opts.include_hidden);
            try dirquery.run();
            const res = dirquery.fileResultArray(&dir_allocator) catch |err| {
                if (err == error.NoResults) std.process.exit(retval);
                return err;
            };
            if (!opts.silent) {
                for (res) |file| {
                    try stdout.print("{s} ", .{file});
                    if (opts.insert_newlines) try stdout.print("\n", .{});
                }
                if (!opts.insert_newlines) try stdout.print("\n", .{});
            }
            retval = 0;
        },
    }

    std.process.exit(retval);
}

test {
    @import("std").testing.refAllDecls(@This());
}
