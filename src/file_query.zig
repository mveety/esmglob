const std = @import("std");
const glob = @import("glob.zig");
const query = @import("query.zig");
const filter_stream = @import("filter_stream.zig");

pub const FileQuery = struct {
    const Self = @This();
    const FileList = std.SinglyLinkedList([]const u8);
    allocator: *std.mem.Allocator,
    complete_match: bool,
    complete_filter: bool,
    pattern: *glob.Glob,
    files: FileList,
    results: FileList,

    pub fn destroy(self: *Self) void {
        while (self.results.popFirst()) |elem| {
            self.allocator.destroy(elem);
        }
        while (self.files.popFirst()) |elem| {
            self.allocator.free(elem.data);
            self.allocator.destroy(elem);
        }
        self.pattern.destroy();
        self.allocator.destroy(self);
    }

    pub fn new(allocator: *std.mem.Allocator, pattern: []const u8) !*Self {
        const newfq = try allocator.create(Self);
        newfq.* = .{
            .allocator = allocator,
            .complete_match = true,
            .complete_filter = true,
            .pattern = try glob.Glob.new(allocator, pattern),
            .files = FileList{},
            .results = FileList{},
        };
        return newfq;
    }

    pub fn configure(
        self: *Self,
        complete_match: bool,
        complete_filter: bool,
    ) void {
        self.complete_match = complete_match;
        self.complete_filter = complete_filter;
    }

    pub fn addFile(self: *Self, f: []const u8) !void {
        const node = try self.allocator.create(FileList.Node);
        errdefer self.allocator.destroy(node);
        node.data = try self.allocator.dupe(u8, f);
        self.files.prepend(node);
    }

    fn addResult(self: *Self, f: []const u8) !void {
        const node = try self.allocator.create(FileList.Node);
        node.data = f;
        self.results.prepend(node);
    }

    pub fn hasResults(self: *Self) bool {
        if (self.results.len() > 0) return true;
        return false;
    }

    pub fn resultArray(self: *Self, allocator: *std.mem.Allocator) ![][]const u8 {
        const reslen = self.results.len();
        if (reslen == 0) return query.QueryError.NoResults;
        var rs = try allocator.alloc([]const u8, reslen);
        errdefer allocator.free(rs);
        var mcur = self.results.first;
        var i: usize = 0;
        while (mcur) |cur| : ({
            mcur = mcur.?.next;
            i += 1;
        }) {
            const fname = try allocator.dupe(u8, cur.data);
            errdefer allocator.free(fname);
            rs[i] = fname;
        }
        return rs;
    }

    pub fn run(self: *Self) !void {
        if (self.files.first == null) return query.QueryError.NoResults;
        var mcur = self.files.first;
        // 32k buffer
        const buffer = try self.allocator.alloc(u8, 32*1024);
        defer self.allocator.free(buffer);
        while (mcur) |cur| : (mcur = mcur.?.next) {
            const file = std.fs.cwd().openFile(cur.data, .{}) catch continue;
            defer file.close();
            const reader = file.reader();
            if (try filter_stream.match_stream(
                self.pattern,
                reader,
                buffer,
                self.complete_match,
                self.complete_filter,
            )) {
                try self.addResult(cur.data);
            }
        }
    }
};
