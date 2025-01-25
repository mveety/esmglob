const std = @import("std");

pub const StringMatch = struct {
    const Self = @This();
    string: []const u8,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        allocator.free(self.string);
        allocator.destroy(self);
    }

    pub fn copy(self: *Self, allocator: *std.mem.Allocator) !*Self {
        const new = try allocator.create(Self);
        new.string = try allocator.dupe(u8, self.string);
        return new;
    }

    pub fn toString(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        return std.fmt.allocPrint(allocator.*, "{s}", .{self.string});
    }

    pub fn printobj(self: *Self) void {
        std.debug.print("{s}", .{self.string});
    }

    pub fn dumpobj(self: *Self) void {
        std.debug.print("({*} \"{s}\")", .{ self, self.string });
    }
};

pub const ClassMatch = struct {
    const Self = @This();
    inverse: bool,
    possible: []const u8,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn copy(self: *Self, allocator: *std.mem.Allocator) !*Self {
        const new = try allocator.create(Self);
        new.inverse = self.inverse;
        new.possible = try allocator.dupe(u8, self.possible);
        return new;
    }

    pub fn toString(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        if (self.inverse) {
            return std.fmt.allocPrint(allocator.*, "[~{s}]", .{self.possible});
        } else {
            return std.fmt.allocPrint(allocator.*, "[{s}]", .{self.possible});
        }
    }

    pub fn printobj(self: *Self) void {
        std.debug.print("[", .{});
        if (self.inverse) std.debug.print("~", .{});
        std.debug.print("{s}]", .{self.possible});
    }

    pub fn dumpobj(self: *Self) void {
        std.debug.print("({*} ", .{self});
        if (self.inverse) std.debug.print("inverse=true ", .{});
        std.debug.print("possible=\"{s}\")", .{self.possible});
    }
};

pub const Wildcard = struct {
    const Self = @This();
    single: bool,
    repeat: usize,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn copy(self: *Self, allocator: *std.mem.Allocator) !*Self {
        const new = try allocator.create(Self);
        new.single = self.single;
        new.repeat = self.repeat;
        return new;
    }

    pub fn toString(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        if (self.single) {
            var i: i32 = 0;
            var tmp = std.ArrayList(u8).init(allocator.*);
            defer tmp.deinit();
            while (i < self.repeat) : (i += 1) {
                try tmp.append('?');
            }
            return tmp.toOwnedSlice();
        } else {
            return std.fmt.allocPrint(allocator.*, "*", .{});
        }
    }

    pub fn printobj(self: *Self) void {
        if (self.single) {
            var i: usize = 0;
            while (i < self.repeat) : (i += 1) {
                std.debug.print("?", .{});
            }
        } else {
            std.debug.print("*", .{});
        }
    }

    pub fn dumpobj(self: *Self) void {
        std.debug.print(
            "({*} single={any} repeat={d})",
            .{ self, self.single, self.repeat },
        );
    }
};

pub const MatchGroup = struct {
    const Self = @This();
    pattern: ?*Pattern,
    next: ?*MatchGroup,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        if (self.next) |next| next.destroy(allocator);
        if (self.pattern) |pattern| pattern.destroy(allocator);
        allocator.destroy(self);
    }

    pub fn copy(self: *Self, allocator: *std.mem.Allocator) !*Self {
        const new = try allocator.create(Self);
        new.pattern = null;
        new.pattern = if (self.pattern) |sp|
            try sp.copy(allocator)
        else
            null;
        if (self.next) |n| {
            new.next = try n.copy(allocator);
        } else {
            new.next = null;
        }
        return new;
    }

    fn toString1(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        const pat = if (self.pattern) |sp|
            try sp.toString(allocator)
        else
            "";
        if (self.next) |n| {
            const nextstring = try n.toString1(allocator);
            return std.fmt.allocPrint(
                allocator.*,
                "|{s}{s}",
                .{ pat, nextstring },
            );
        } else {
            return std.fmt.allocPrint(allocator.*, "|{s})", .{pat});
        }
    }

    pub fn toString(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        const pat = if (self.pattern) |sp|
            try sp.toString(allocator)
        else
            "";
        if (self.next) |n| {
            const nextstring = try n.toString1(allocator);
            return std.fmt.allocPrint(
                allocator.*,
                "({s}{s}",
                .{ pat, nextstring },
            );
        } else {
            return std.fmt.allocPrint(allocator.*, "({s})", .{pat});
        }
    }

    fn print1(self: *Self, first: bool) void {
        if (first) std.debug.print("(", .{});
        if (self.pattern) |sp| sp.printobj();
        if (self.next) |n| {
            std.debug.print("|", .{});
            n.print1(false);
        } else {
            std.debug.print(")", .{});
        }
    }

    pub fn printobj(self: *Self) void {
        self.print1(true);
    }

    fn dumpobj1(self: *Self, first: bool) void {
        if (first) std.debug.print("({*} ", .{self});
        if (!first) std.debug.print("<{*}>", .{self});
        if (self.pattern) |sp| {
            sp.dumpobj();
        } else {
            std.debug.print("()", .{});
        }
        if (self.next) |n| {
            std.debug.print(" ", .{});
            n.dumpobj1(false);
        } else {
            std.debug.print(")", .{});
        }
    }

    pub fn dumpobj(self: *Self) void {
        self.dumpobj1(true);
    }
};

pub const PatternTag = enum {
    string,
    class,
    wildcard,
    match,
};

pub const PatternError = error{
    OutOfMemory,
    EmptyPattern,
};

pub const Pattern = struct {
    const Self = @This();
    data: union(PatternTag) {
        string: *StringMatch,
        class: *ClassMatch,
        wildcard: *Wildcard,
        match: *MatchGroup,
    },
    next: ?*Pattern,

    pub fn destroy(self: *Self, allocator: *std.mem.Allocator) void {
        if (self.next) |next| next.destroy(allocator);
        switch (self.data) {
            .string => self.data.string.destroy(allocator),
            .class => self.data.class.destroy(allocator),
            .wildcard => self.data.wildcard.destroy(allocator),
            .match => self.data.match.destroy(allocator),
        }
        allocator.destroy(self);
    }

    pub fn copy(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError!*Self {
        const new = try allocator.create(Self);
        new.data = switch (self.data) {
            .string => .{ .string = try self.data.string.copy(allocator) },
            .class => .{ .class = try self.data.class.copy(allocator) },
            .wildcard => .{ .wildcard = try self.data.wildcard.copy(allocator) },
            .match => .{ .match = try self.data.match.copy(allocator) },
        };
        if (self.next) |n| {
            new.next = try n.copy(allocator);
        } else {
            new.next = null;
        }
        return new;
    }

    pub fn toString(
        self: *Self,
        allocator: *std.mem.Allocator,
    ) PatternError![]const u8 {
        const childstring = switch (self.data) {
            .string => try self.data.string.toString(allocator),
            .class => try self.data.class.toString(allocator),
            .wildcard => try self.data.wildcard.toString(allocator),
            .match => try self.data.match.toString(allocator),
        };
        if (self.next) |n| {
            const nextstring = try n.toString(allocator);
            return std.fmt.allocPrint(
                allocator.*,
                "{s}{s}",
                .{ childstring, nextstring },
            );
        } else {
            return childstring;
        }
    }

    pub fn printobj(self: *Self) void {
        switch (self.data) {
            .string => self.data.string.printobj(),
            .class => self.data.class.printobj(),
            .wildcard => self.data.wildcard.printobj(),
            .match => self.data.match.printobj(),
        }
        if (self.next) |n| {
            n.printobj();
        }
    }

    fn dumpobj1(self: *Self) void {
        std.debug.print("<{*}>", .{self});
        switch (self.data) {
            .string => self.data.string.dumpobj(),
            .class => self.data.class.dumpobj(),
            .wildcard => self.data.wildcard.dumpobj(),
            .match => self.data.match.dumpobj(),
        }
        if (self.next) |n| {
            std.debug.print(" ", .{});
            n.dumpobj1();
        } else {
            std.debug.print(")", .{});
        }
    }

    pub fn dumpobj(self: *Self) void {
        std.debug.print("({*} ", .{self});
        self.dumpobj1();
    }

    pub fn append(self: *Self, plist: *Self) void {
        if (self.next) |n| {
            append(n, plist);
        } else {
            self.next = plist;
        }
    }
};

pub fn nPatternCopies(
    allocator: *std.mem.Allocator,
    p: *Pattern,
    mnp: ?*Pattern,
    n: usize,
) PatternError!*Pattern {
    if (n <= 0) {
        const np = mnp orelse return PatternError.EmptyPattern;
        return np;
    }
    if (mnp) |np| {
        np.append(try p.copy(allocator));
        return nPatternCopies(allocator, p, np, n - 1);
    } else {
        return nPatternCopies(allocator, p, try p.copy(allocator), n - 1);
    }
}

pub fn nCloneCopies(
    allocator: *std.mem.Allocator,
    p: *Pattern,
    n: usize,
) !*Pattern {
    const np = try p.copy(allocator);

    return nPatternCopies(allocator, np, null, n);
}
