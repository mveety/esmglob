const std = @import("std");
const patterns = @import("patterns.zig");
const glob = @import("glob.zig");
const matching = @import("matching.zig");

// this is pretty trash. if you search a tree it
// searches the whole tree, not just dirs with partial matches
// i did some work on partial path matching but it isn't
// needed for the application.
// this whole thing is gravy not really a priority

fn openDir(mpath: ?[]const u8) anyerror!std.fs.Dir {
    if (mpath) |path| {
        if (path[0] == '/')
            return std.fs.openDirAbsolute(path, .{ .iterate = true });
        return std.fs.cwd().openDir(path, .{ .iterate = true });
    } else {
        return std.fs.cwd().openDir(".", .{ .iterate = true });
    }
}

pub const DirQuery = struct {
    const Self = @This();
    const ResultsList = std.SinglyLinkedList(*std.fs.Dir.Entry);
    const QueryResults = struct {
        files: ResultsList,
        dirs: ResultsList,
    };

    allocator: *std.mem.Allocator,
    complete_match: bool = true,
    complete_filter: bool = true,
    search_tree: bool = false,
    include_hidden: bool = false,
    mpath: ?[]const u8,
    rootdir: std.fs.Dir,
    pattern: *glob.Glob,
    results: ResultsList,
    dirs: ResultsList,

    pub fn destroy(self: *Self) void {
        while (self.results.popFirst()) |elem| {
            self.allocator.free(elem.data);
            self.allocator.destroy(elem);
        }
        while (self.dirs.popFirst()) |elem| {
            self.allocator.free(elem.data);
            self.allocator.destroy(elem);
        }
        self.pattern.destroy();
        self.allocator.destroy(self);
    }

    pub fn new(allocator: *std.mem.Allocator, pattern: []const u8, mpath: ?[]const u8) !*Self {
        const newq = try allocator.create(Self);
        errdefer allocator.destroy(newq);
        const realpath = if (mpath) |path| try allocator.dupe(u8, path) else null;

        newq.* = .{
            .allocator = allocator,
            .mpath = realpath,
            .rootdir = try openDir(realpath),
            .pattern = try glob.Glob.new(allocator, pattern),
            .results = ResultsList{},
            .dirs = ResultsList{},
        };
        return newq;
    }

    pub fn configure(
        self: *Self,
        complete_match: bool,
        complete_filter: bool,
        search_tree: bool,
        include_hidden: bool,
    ) void {
        self.complete_match = complete_match;
        self.complete_filter = complete_filter;
        self.search_tree = search_tree;
        self.include_hidden = include_hidden;
    }

    fn addResult(self: *Self, l: *ResultsList, ent: *std.fs.Dir.Entry) !void {
        const node = try self.allocator.create(ResultsList.Node);
        node.* = .{ .data = ent };
        l.prepend(node);
    }

    fn prefixDir(
        allocator: *std.mem.Allocator,
        mpath: ?[]const u8,
        name: []const u8,
        postfix_slash: bool,
    ) ![]const u8 {
        const slash = if (postfix_slash) "/" else "";

        if (mpath) |path| {
            return std.fmt.allocPrint(allocator.*, "{s}/{s}{s}", .{ path, name, slash });
        } else {
            return std.fmt.allocPrint(allocator.*, "{s}{s}", .{ name, slash });
        }
    }

    fn matchDirectory(
        self: *Self,
        dir: std.fs.Dir,
        mprefix: ?[]const u8,
        match_all_dirs: bool,
    ) !*QueryResults {
        const results = try self.allocator.create(QueryResults);
        errdefer self.allocator.destroy(results);
        results.* = .{
            .files = ResultsList{},
            .dirs = ResultsList{},
        };
        var query_arena = std.heap.ArenaAllocator.init(self.allocator.*);
        defer query_arena.deinit();
        var query_allocator = query_arena.allocator();

        var iter = dir.iterate();

        while (try iter.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (match_all_dirs) {
                        if (!self.include_hidden and entry.name[0] == '.') continue;
                        var entcopy = try self.allocator.create(std.fs.Dir.Entry);
                        errdefer self.allocator.destroy(entcopy);
                        entcopy.kind = .directory;
                        entcopy.name = try prefixDir(self.allocator, mprefix, entry.name, false);
                        try self.addResult(&results.dirs, entcopy);
                    } else {
                        const tmpname = try prefixDir(&query_allocator, mprefix, entry.name, false);
                        defer query_allocator.free(tmpname);
                        if (matching.match(
                            self.pattern,
                            tmpname,
                            self.complete_match,
                            self.complete_filter,
                        )) {
                            var entcopy = try self.allocator.create(std.fs.Dir.Entry);
                            errdefer self.allocator.destroy(entcopy);
                            entcopy.kind = .directory;
                            entcopy.name = try self.allocator.dupe(u8, tmpname);
                            try self.addResult(&results.dirs, entcopy);
                        }
                    }
                },
                else => {
                    if (!self.include_hidden) {
                        if (entry.name[0] == '.') continue;
                    }
                    const tmpname = try prefixDir(&query_allocator, mprefix, entry.name, false);
                    defer query_allocator.free(tmpname);
                    if (matching.match(self.pattern, tmpname, self.complete_match, self.complete_filter)) {
                        const entcopy = try self.allocator.create(std.fs.Dir.Entry);
                        errdefer self.allocator.destroy(entcopy);
                        entcopy.* = .{
                            .kind = entry.kind,
                            .name = try self.allocator.dupe(u8, tmpname),
                        };
                        try self.addResult(&results.files, entcopy);
                    }
                },
            }
        }
        return results;
    }

    const SearchJob = struct {
        dir: std.fs.Dir,
        mprefix: ?[]const u8,
        dontfree: bool = false,
    };
    const SearchQueue = std.DoublyLinkedList(*SearchJob);

    fn runTree(self: *Self) !void {
        var dirlist = SearchQueue{};
        var job_arena = std.heap.ArenaAllocator.init(self.allocator.*);
        defer job_arena.deinit();
        var job_allocator = job_arena.allocator();

        const first_job = try job_allocator.create(SearchJob);
        first_job.* = .{
            .dir = self.rootdir,
            .mprefix = self.mpath,
            .dontfree = true,
        };
        var first_node = SearchQueue.Node{ .data = first_job };
        dirlist.append(&first_node);

        while (dirlist.popFirst()) |node| {
            const queryres = try self.matchDirectory(node.data.dir, node.data.mprefix, true);
            defer self.allocator.destroy(queryres);
            while (queryres.files.popFirst()) |n| {
                self.results.prepend(n);
            }
            while (queryres.dirs.popFirst()) |n| {
                var newjob = try job_allocator.create(SearchJob);
                var newnode = try job_allocator.create(SearchQueue.Node);
                newjob.mprefix = n.data.name;
                // this kinda sucks but should work
                newjob.dir = try self.rootdir.openDir(n.data.name, .{ .iterate = true });
                newnode.data = newjob;
                dirlist.append(newnode);
                self.dirs.prepend(n);
            }
            if (!node.data.dontfree) node.data.dir.close();
        }
    }

    fn runRoot(self: *Self) !void {
        const queryres = try self.matchDirectory(self.rootdir, self.mpath, false);
        defer self.allocator.destroy(queryres);
        while (queryres.files.popFirst()) |n| {
            self.results.prepend(n);
        }
        while (queryres.dirs.popFirst()) |n| {
            self.dirs.prepend(n);
        }
    }

    pub fn run(self: *Self) !void {
        if (self.search_tree) {
            try self.runTree();
        } else {
            try self.runRoot();
        }
    }

    pub fn fileResultArray(self: *Self, allocator: *std.mem.Allocator) ![][]const u8 {
        const reslen = self.results.len();
        if (reslen == 0) return error.NoResults;
        var res = try allocator.alloc([]const u8, reslen);
        errdefer allocator.free(res);
        var mcur = self.results.first;
        var i: usize = 0;
        while (mcur) |cur| : ({
            mcur = cur.next;
            i += 1;
        }) {
            const fname = try allocator.dupe(u8, cur.data.name);
            errdefer allocator.free(fname);
            res[i] = fname;
        }
        return res;
    }
};

test "direct_query basic test" {
    var allocator = std.heap.page_allocator;
    const query = try DirQuery.new(&allocator, "*", null);
    try query.run();
    _ = try query.fileResultArray(&allocator);

    //    std.debug.print("\n", .{});
    //    std.debug.print("query = {s}\n", .{try query.pattern.toString(&allocator)});
    //    for (res) |file| {
    //        std.debug.print("found file: {s}\n", .{file});
    //    }
}

// this test is only useful in src/
//test "direct_query actually filter test" {
//    var allocator = std.heap.page_allocator;
//    const query = try DirQuery.new(&allocator, "(m*|f*).zig", null);
//    try query.run();
//    const res = try query.fileResultArray(&allocator);
//
//    std.debug.print("\n", .{});
//    std.debug.print("query = {s}\n", .{try query.pattern.toString(&allocator)});
//    for (res) |file| {
//        std.debug.print("found file: {s}\n", .{file});
//    }
//}
