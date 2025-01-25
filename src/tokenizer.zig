const std = @import("std");

pub const TokenType = enum {
    const Self = @This();
    class_start,
    class_end,
    class_inverse,

    match_set_start,
    match_set_next,
    match_set_end,

    macro_start,
    range_start,
    range_next_field,
    range_end,

    qmark,
    wildcard,

    number,
    string,
    escaped,

    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .class_start => "class_start",
            .class_end => "class_end",
            .class_inverse => "class_inverse",
            .match_set_start => "match_set_start",
            .match_set_next => "match_set_next",
            .match_set_end => "match_set_end",
            .macro_start => "macro_start",
            .range_start => "range_start",
            .range_next_field => "range_next_field",
            .range_end => "range_end",
            .qmark => "qmark",
            .wildcard => "wildcard",
            .number => "number",
            .string => "string",
            .escaped => "escaped",
        };
    }
};

pub const ParserState = enum {
    default,
    string,
    number,
};

pub const ParsingError = error{
    InvalidState,
};

pub const Token = struct {
    const Self = @This();
    typ: TokenType,
    string: []const u8,
    next: ?*Token,
    prev: ?*Token,

    pub fn create(
        allocator: *std.mem.Allocator,
        typ: TokenType,
        string: []const u8,
    ) !*Token {
        var t = try allocator.create(Token);

        t.typ = typ;
        t.string = string;
        t.next = null;
        t.prev = null;
        return t;
    }

    pub fn printobj1(self: *Self) void {
        std.debug.print(
            "token {{ typ = \"{s}\" ",
            .{self.typ.toString()},
        );
        std.debug.print("string = \"{s}\" }}", .{self.string});
    }

    pub fn printToken(self: *Self) void {
        self.printobj1();
        std.debug.print("\n", .{});
    }

    pub fn printobj(self: *Self) void {
        self.printobj1();
        std.debug.print("\n", .{});
        if (self.next) |next| {
            next.printobj();
        }
    }
};

pub const Tokens = struct {
    const Self = @This();
    head: ?*Token,
    cur: ?*Token,
    parsecur: ?*Token,
    allocator: *std.mem.Allocator,

    pub fn printobj(self: *Self) void {
        if (self.head) |sh| {
            sh.printobj();
        }
    }

    pub fn create(allocator: *std.mem.Allocator) !*Tokens {
        var t = try allocator.create(Tokens);

        t.allocator = allocator;
        t.head = null;
        t.cur = null;
        t.parsecur = null;
        return t;
    }

    pub fn add_token(self: *Self, typ: TokenType, string: []const u8) !void {
        const newtok: *Token = try Token.create(self.allocator, typ, string);

        // im going to assume self.head is != null here
        if (self.cur) |cur| {
            cur.next = newtok;
            newtok.prev = cur;
            self.cur = cur.next;
        } else {
            self.head = newtok;
            self.cur = newtok;
        }
    }

    pub fn next_token(self: *Self) ?*Token {
        if (self.parsecur) |pc| {
            self.parsecur = pc.next;
            return self.parsecur;
        } else {
            self.parsecur = self.head;
            return self.parsecur;
        }
    }

    pub fn peek_token(self: *Self) ?*Token {
        return self.parsecur;
    }

    pub fn peek_next(self: *Self) ?*Token {
        if (self.parsecur) |pc| {
            return pc.next;
        }
        return self.head;
    }

    pub fn prev_token(self: *Self) ?*Token {
        if (self.parsecur) |pc| {
            if (pc.prev) |pcp| {
                self.parsecur = pcp;
                return pcp;
            } else {
                return null;
            }
        } else {
            return null;
        }
    }

    pub fn cur_token(self: *Self) ?*Token {
        return self.parsecur;
    }
};

pub fn tokenize_string(allocator: *std.mem.Allocator, string: []const u8) !*Tokens {
    var tmpres = std.ArrayList(u8).init(allocator.*);
    defer tmpres.deinit();
    var state: ParserState = .default;
    var tokens = try Tokens.create(allocator);
    var escaped = false;
    var i: usize = 0;

    var c: u8 = string[i];
    while (i < string.len) {
        c = string[i];
        switch (state) {
            .default => {
                switch (c) {
                    '[' => try tokens.add_token(.class_start, "["),
                    ']' => try tokens.add_token(.class_end, "]"),
                    '~' => try tokens.add_token(.class_inverse, "~"),
                    '(' => try tokens.add_token(.match_set_start, "("),
                    '|' => try tokens.add_token(.match_set_next, "|"),
                    ')' => try tokens.add_token(.match_set_end, ")"),
                    '%' => try tokens.add_token(.macro_start, "%"),
                    '<' => try tokens.add_token(.range_start, "<"),
                    '-' => try tokens.add_token(.range_next_field, "-"),
                    '>' => try tokens.add_token(.range_end, ">"),
                    '?' => try tokens.add_token(.qmark, "?"),
                    '*' => try tokens.add_token(.wildcard, "*"),

                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        state = .number;
                        tmpres.clearAndFree();
                    },
                    '\\' => {
                        state = .string;
                        tmpres.clearAndFree();
                        escaped = true;
                    },
                    else => {
                        state = .string;
                        tmpres.clearAndFree();
                    },
                }
                if (state == .default) {
                    i += 1;
                    if (i > string.len)
                        break;
                }
            },
            .number => {
                switch (c) {
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        try tmpres.append(c);
                    },
                    '[', ']', '~', '(', '|', ')', '%', '<', '-', '>', '?', '*' => {
                        state = .default;
                    },
                    else => {
                        if (c == '\\') escaped = true;
                        state = .string;
                    },
                }
                if (state != .number) {
                    const tmpslice = try tmpres.toOwnedSlice();
                    try tokens.add_token(.number, tmpslice);
                } else {
                    i += 1;
                    if (i > string.len)
                        break;
                }
            },
            .string => {
                if (escaped) {
                    i += 1; // the \
                    if (i >= string.len)
                        break;
                    c = string[i]; // the thing we want
                    try tmpres.append(c);
                    i += 1;
                    if (i >= string.len)
                        break;
                    escaped = false;
                    continue;
                }
                switch (c) {
                    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                        state = .number;
                    },
                    '[', ']', '~', '(', '|', ')', '%', '<', '-', '>', '?', '*' => {
                        state = .default;
                    },
                    '\\' => {
                        escaped = true;
                        continue;
                    },
                    '/' => {
                        // pop slashes out as their own token so we can easily
                        // catch then when searching dirs, but we keep them
                        // strings to make use of the exsiting machinery.
                        const tmpslice = try tmpres.toOwnedSlice();
                        if (tmpslice.len > 0) // leading / doesn't have a preceding string/number
                            try tokens.add_token(.string, tmpslice); // preceding string
                        try tmpres.append(c);
                        const slashslice = try tmpres.toOwnedSlice();
                        try tokens.add_token(.string, slashslice); // the slash
                    },
                    else => try tmpres.append(c),
                }
                if (state != .string) {
                    const tmpslice = try tmpres.toOwnedSlice();
                    try tokens.add_token(.string, tmpslice);
                } else {
                    i += 1;
                    if (i > string.len)
                        break;
                }
            },
        }
    }
    switch (state) {
        .string => {
            const tmpslice = try tmpres.toOwnedSlice();
            try tokens.add_token(.string, tmpslice);
        },
        .number => {
            const tmpslice = try tmpres.toOwnedSlice();
            try tokens.add_token(.number, tmpslice);
        },
        else => {},
    }

    return tokens;
}

fn tokeql(mt: ?*Token, typ: TokenType) !void {
    const t = mt orelse return error.NullToken;
    if (t.typ != typ) return error.BadToken;
}

// these were more or less autogenerated from the output of
// the c implementation's tokenizer.
test "basic tokenizer" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello12345(%[0-9]<10-12>|is|?12|test)";

    const toks = tokenize_string(&allocator, test_input) catch unreachable;

    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .match_set_start);
    try tokeql(toks.next_token(), .macro_start);
    try tokeql(toks.next_token(), .class_start);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .range_next_field);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .class_end);
    try tokeql(toks.next_token(), .range_start);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .range_next_field);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .range_end);
    try tokeql(toks.next_token(), .match_set_next);
    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .match_set_next);
    try tokeql(toks.next_token(), .qmark);
    try tokeql(toks.next_token(), .number);
    try tokeql(toks.next_token(), .match_set_next);
    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .match_set_end);
    try std.testing.expect(toks.next_token() == null);
}

test "tokenizer trailing escaped exclaimation point" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello*\\!";

    const toks = tokenize_string(&allocator, test_input) catch unreachable;

    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .wildcard);
    try tokeql(toks.next_token(), .string);
    try std.testing.expect(toks.next_token() == null);
}

test "tokenizer escaped exclaimation point" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello*\\!a";

    const toks = tokenize_string(&allocator, test_input) catch unreachable;

    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .wildcard);
    try tokeql(toks.next_token(), .string);
    try std.testing.expect(toks.next_token() == null);
}

// these are copy paste jobs of the above but cover new functionality
test "tokenizer slash test" {
    var allocator = std.heap.page_allocator;
    const test_input = "dira/dirb";

    const toks = tokenize_string(&allocator, test_input) catch unreachable;

    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .string);
    try std.testing.expect(toks.next_token() == null);
}

test "tokenizer leading slash test" {
    var allocator = std.heap.page_allocator;
    const test_input = "/usr/bin";

    const toks = tokenize_string(&allocator, test_input) catch unreachable;

    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .string);
    try tokeql(toks.next_token(), .string);
    try std.testing.expect(toks.next_token() == null);
}
