const std = @import("std");
const glob = @import("glob.zig");
const matching = @import("matching.zig");

pub const QueryError = error{
    NoResults,
    NoData,
} || glob.CompilerError;

pub const QueryElem = struct {
    const Self = @This();
    string: []const u8,
    extra: ?[]const u8,

    pub fn new(
        allocator: *std.mem.Allocator,
        s: []const u8,
        me: ?[]const u8,
    ) !*QueryElem {
        const newql = try allocator.create(Self);
        errdefer allocator.destroy(newql);
        newql.string = try allocator.dupe(u8, s);
        errdefer allocator.free(newql.string);
        newql.extra = if (me) |e| try allocator.dupe(u8, e) else null;
        return newql;
    }

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        if (self.extra) |e| allocator.free(e);
        allocator.free(self.string);
        allocator.destroy(self);
    }
};

const QueryList = std.SinglyLinkedList(*QueryElem);

pub const Query = struct {
    const Self = @This();
    allocator: *std.mem.Allocator,
    pattern: *glob.Glob,
    complete_match: bool,
    complete_filter: bool,
    source: QueryList,
    result: QueryList,

    pub fn destroy(self: *Self) void {
        self.clear();
        self.pattern.destroy();
        self.allocator.destroy(self);
    }

    pub fn new(allocator: *std.mem.Allocator, pat: []const u8) !*Self {
        const newquery = try allocator.create(Self);
        errdefer allocator.destroy(newquery);
        newquery.* = .{
            .allocator = allocator,
            .pattern = try glob.Glob.new(allocator, pat),
            .complete_match = true,
            .complete_filter = true,
            .source = QueryList{},
            .result = QueryList{},
        };
        return newquery;
    }

    pub fn configure(
        self: *Self,
        complete_match: bool,
        complete_filter: bool,
    ) void {
        self.complete_match = complete_match;
        self.complete_filter = complete_filter;
    }

    pub fn addData(self: *Self, s: []const u8, e: ?[]const u8) !void {
        const node = try self.allocator.create(QueryList.Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .data = try QueryElem.new(self.allocator, s, e) };
        self.source.prepend(node);
    }

    pub fn clear(self: *Self) void {
        while (self.result.popFirst()) |elem| {
            self.allocator.destroy(elem);
        }
        while (self.source.popFirst()) |elem| {
            elem.data.destroy(self.allocator);
            self.allocator.destroy(elem);
        }
    }

    pub fn reset(self: *Self) void {
        while (self.result.popFirst()) |elem| {
            self.allocator.destroy(elem);
        }
    }

    fn addResult(self: *Self, qe: *QueryElem) !void {
        const node = try self.allocator.create(QueryList.Node);
        node.* = .{ .data = qe };
        self.result.prepend(node);
    }

    pub fn hasResults(self: *Self) bool {
        if (self.result.len() > 0) return true;
        return false;
    }

    pub fn resultArray(self: *Self, allocator: *std.mem.Allocator) ![]QueryElem {
        const reslen = self.result.len();
        if (reslen == 0) return QueryError.NoResults;
        var qeslice = try allocator.alloc(QueryElem, reslen);
        errdefer allocator.free(qeslice);
        var mcur = self.result.first;
        var i: usize = 0;
        while (mcur) |cur| : ({
            mcur = mcur.?.next;
            i += 1;
        }) {
            qeslice[i] = .{
                .string = try allocator.dupe(u8, cur.data.string),
                .extra = if (cur.data.extra) |e|
                    try allocator.dupe(u8, e)
                else
                    null,
            };
        }
        return qeslice;
    }

    pub fn run(self: *Self) !void {
        if (self.source.first == null) return QueryError.NoData;
        var mcur = self.source.first;
        while (mcur) |cur| : (mcur = mcur.?.next) {
            const qe = cur.data;
            if (matching.match(
                self.pattern,
                qe.string,
                self.complete_match,
                self.complete_filter,
            )) {
                try self.addResult(qe);
            }
        }
    }
};

test "query basic query" {
    var allocator = std.heap.page_allocator;
    const query = try Query.new(&allocator, "*");
    try query.addData("hello", null);
    try query.addData("world", null);
    try query.run();
    try std.testing.expect(query.hasResults());
    const reses = try query.resultArray(&allocator);
    query.destroy();
    try std.testing.expect(reses.len == 2);
    try std.testing.expect(std.mem.eql(u8, reses[0].string, "hello"));
    try std.testing.expect(std.mem.eql(u8, reses[1].string, "world"));
}

test "query one fails" {
    var allocator = std.heap.page_allocator;
    const query = try Query.new(&allocator, "h*");
    try query.addData("hello", null);
    try query.addData("world", null);
    try query.run();
    try std.testing.expect(query.hasResults());
    const reses = try query.resultArray(&allocator);
    query.destroy();
    try std.testing.expect(reses.len == 1);
    try std.testing.expect(std.mem.eql(u8, reses[0].string, "hello"));
}

test "query all fail" {
    var allocator = std.heap.page_allocator;
    const query = try Query.new(&allocator, "hahno");
    try query.addData("hello", null);
    try query.addData("world", null);
    try query.run();
    try std.testing.expect(!query.hasResults());
    _ = query.resultArray(&allocator) catch |err| {
        if (err != QueryError.NoResults) return err;
    };
}
