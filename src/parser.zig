const std = @import("std");
const tokenizer = @import("tokenizer.zig");
const patterns = @import("patterns.zig");

pub const ParseError = error{
    InvalidToken,
    IncompleteTerm,
    TooManyTokens,
    TokenTooLong,
    InvalidRange,
    OutOfMemory,
    BadList,
    Overflow,
    InvalidCharacter,
    EmptyPattern,
};

pub const ErrorInfo = struct {
    const Self = @This();
    allocator: *std.mem.Allocator,
    msg: ?[]const u8,
    err: ?anyerror,
    token: ?*tokenizer.Token,

    pub fn new(allocator: *std.mem.Allocator) Self {
        return ErrorInfo{
            .allocator = allocator,
            .msg = undefined,
            .err = undefined,
            .token = undefined,
        };
    }

    pub fn print(self: *Self) void {
        if (self.msg) |smsg| std.debug.print("error message: \"{s}\"\n", .{smsg});
        if (self.err) |serr| std.debug.print("error: {!}\n", .{serr});
        if (self.token) |token| {
            std.debug.print("token: ", .{});
            token.printToken();
        }
    }
};

fn errmsg1(allocator: *std.mem.Allocator, e: ParseError) ![]const u8 {
    return try std.fmt.allocPrint(allocator.*, "error: {!}", .{e});
}

fn errmsg2(
    allocator: *std.mem.Allocator,
    e: ParseError,
    s: []const u8,
) ![]const u8 {
    return try std.fmt.allocPrint(allocator.*, "error: {!}: {s}", .{ e, s });
}

fn doerr(merr: ?*ErrorInfo, e: ParseError) ParseError {
    const err = merr orelse return e;
    err.msg = errmsg1(err.allocator, e) catch "ALLOCATION ERROR";
    err.err = e;
    err.token = null;
    return e;
}

fn doerr2(merr: ?*ErrorInfo, e: ParseError, s: []const u8) ParseError {
    const err = merr orelse return e;
    err.msg = errmsg2(err.allocator, e, s) catch "ALLOCATION ERROR";
    err.err = e;
    err.token = null;
    return e;
}

fn tokerr(merr: ?*ErrorInfo, e: ParseError, t: *tokenizer.Token) ParseError {
    const err = merr orelse return e;
    err.msg = errmsg2(err.allocator, e, t.string) catch "ALLOCATION ERROR";
    err.err = e;
    err.token = t;
    return e;
}

pub fn parse_tokens(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const t = toks.peek_next() orelse return null;

    return switch (t.typ) {
        .class_start => parse_class(allocator, toks, merr),
        .match_set_start => parse_match_set(allocator, toks, merr),
        .match_set_next, .match_set_end, .range_start => null,
        .macro_start => parse_macro(allocator, toks, merr),
        .qmark, .wildcard => parse_wildcard(allocator, toks, merr),
        .number, .string => parse_string(allocator, toks, merr),
        else => ParseError.InvalidToken,
    };
}

fn parse_wildcard(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const p = try allocator.create(patterns.Pattern);
    const trigger_t = toks.next_token() orelse unreachable;

    switch (trigger_t.typ) {
        .wildcard => {
            p.data = .{ .wildcard = try allocator.create(patterns.Wildcard) };
            p.data.wildcard.* = .{
                .single = false,
                .repeat = 0,
            };
        },
        .qmark => {
            if (toks.peek_next()) |pt| {
                switch (pt.typ) {
                    .number => {
                        p.data = .{ .wildcard = try allocator.create(patterns.Wildcard) };
                        p.data.wildcard.single = true;
                        const t = toks.next_token() orelse unreachable;
                        p.data.wildcard.repeat = std.fmt.parseInt(usize, t.string, 10) catch |e| {
                            return tokerr(merr, e, t);
                        };
                    },
                    .range_start => {
                        var t = toks.next_token() orelse unreachable;

                        t = toks.next_token() orelse
                            return doerr(merr, ParseError.IncompleteTerm);
                        if (t.typ != .number)
                            return tokerr(merr, ParseError.InvalidToken, t);
                        const startn = try std.fmt.parseInt(usize, t.string, 10);
                        t = toks.next_token() orelse
                            return doerr(merr, ParseError.IncompleteTerm);
                        if (t.typ != .range_next_field)
                            return tokerr(merr, ParseError.InvalidToken, t);

                        t = toks.next_token() orelse
                            return doerr(merr, ParseError.IncompleteTerm);
                        if (t.typ != .number)
                            return tokerr(merr, ParseError.InvalidToken, t);
                        const endn = try std.fmt.parseInt(usize, t.string, 10);

                        t = toks.next_token() orelse
                            return doerr(merr, ParseError.IncompleteTerm);
                        if (t.typ != .range_end)
                            return tokerr(merr, ParseError.InvalidToken, t);
                        if (startn > endn) {
                            const ce = ParseError.InvalidRange;
                            const err = merr orelse return ce;
                            err.* = .{
                                .allocator = err.allocator,
                                .msg = try std.fmt.allocPrint(
                                    allocator.*,
                                    "error: {!}: startn:{d} > endn:{d}",
                                    .{ ce, startn, endn },
                                ),
                                .err = ce,
                                .token = null,
                            };
                            return ce;
                        }
                        if (startn == endn) {
                            p.data = .{ .wildcard = try allocator.create(patterns.Wildcard) };
                            p.data.wildcard.* = .{
                                .single = true,
                                .repeat = startn,
                            };
                        } else {
                            var mg = try allocator.create(patterns.MatchGroup);
                            p.data = .{ .match = mg };
                            const tp = try allocator.create(patterns.Pattern);
                            defer tp.destroy(allocator);
                            tp.data = .{ .wildcard = try allocator.create(patterns.Wildcard) };
                            tp.next = null;
                            var i = startn;

                            while (i <= endn) : (i += 1) {
                                tp.data.wildcard.* = .{ .single = true, .repeat = i };
                                mg.pattern = try tp.copy(allocator);
                                mg.next = null;
                                if (i < endn) {
                                    mg.next = try allocator.create(patterns.MatchGroup);
                                    mg = mg.next.?;
                                }
                            }
                        }
                    },
                    else => {
                        p.data = .{ .wildcard = try allocator.create(patterns.Wildcard) };
                        p.data.wildcard.* = .{
                            .single = true,
                            .repeat = 0,
                        };
                    },
                }
            }
        },
        else => return tokerr(merr, ParseError.InvalidToken, trigger_t),
    }
    p.next = try parse_tokens(allocator, toks, merr);
    return p;
}

fn parse_string(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const p = try allocator.create(patterns.Pattern);
    const t = toks.next_token() orelse unreachable;

    p.data = .{ .string = try allocator.create(patterns.StringMatch) };
    p.data.string.string = try allocator.dupe(u8, t.string);
    p.next = try parse_tokens(allocator, toks, merr);
    return p;
}

fn generate_class_string(
    allocator: *std.mem.Allocator,
    start: []const u8,
    end: []const u8,
    merr: ?*ErrorInfo,
) ParseError![]u8 {
    if (start.len != 1 or end.len != 1) {
        const errstr = try std.fmt.allocPrint(
            allocator.*,
            "start.len = {d}, end.len = {d}",
            .{ start.len, end.len },
        );
        return doerr2(merr, ParseError.TokenTooLong, errstr);
    }
    const s = start[0];
    const e = end[0];

    if (!((std.ascii.isDigit(s) and std.ascii.isDigit(e)) or
        (std.ascii.isAlphabetic(s) and std.ascii.isAlphabetic(e))))
    {
        return doerr2(
            merr,
            ParseError.InvalidToken,
            try std.fmt.allocPrint(
                allocator.*,
                "s = \"{c}\", e = \"{c}\"",
                .{ s, e },
            ),
        );
    }

    if (s > e) return doerr2(
        merr,
        ParseError.InvalidRange,
        try std.fmt.allocPrint(
            allocator.*,
            "{c} > {c}",
            .{ s, e },
        ),
    );

    var tmplist = std.ArrayList(u8).init(allocator.*);
    defer tmplist.deinit();
    var i = start[0];
    while (i <= e) : (i += 1) {
        if (std.ascii.isDigit(i) or std.ascii.isAlphabetic(i))
            try tmplist.append(i);
    }
    const res = try tmplist.toOwnedSlice();
    return res;
}

fn parse_class(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const p = try allocator.create(patterns.Pattern);
    const class = try allocator.create(patterns.ClassMatch);
    _ = toks.next_token() orelse unreachable; // ditch the [
    var t = toks.next_token() orelse return doerr(merr, ParseError.IncompleteTerm);
    var inverse_class = false;

    // check for ~
    if (t.typ == .class_inverse) {
        inverse_class = true;
        t = toks.next_token() orelse return doerr(merr, ParseError.IncompleteTerm);
    }

    // must be a string or number for a class
    switch (t.typ) {
        .string, .number => {
            const stmp1 = try allocator.dupe(u8, t.string);
            defer allocator.free(stmp1);
            const lasttype = t.typ;
            const tn = toks.peek_next() orelse
                return doerr(merr, ParseError.IncompleteTerm);
            if (tn.typ == .class_end) {
                // if it's [:stuff:] we're done.
                class.inverse = inverse_class;
                class.possible = try allocator.dupe(u8, t.string);
                _ = toks.next_token() orelse unreachable;
            } else {
                t = toks.next_token() orelse unreachable;
                // dealing with [:stuff:-:stuff:]
                if (t.typ != .range_next_field)
                    return tokerr(merr, ParseError.InvalidToken, t);
                t = toks.next_token() orelse
                    return doerr(merr, ParseError.IncompleteTerm);
                if (t.typ == .class_end)
                    return tokerr(merr, ParseError.IncompleteTerm, t);
                if (t.typ != lasttype)
                    return tokerr(merr, ParseError.InvalidToken, t);
                const stmp2 = try allocator.dupe(u8, t.string);
                defer allocator.free(stmp2);
                t = toks.next_token() orelse
                    return doerr(merr, ParseError.IncompleteTerm);
                if (t.typ != .class_end)
                    return tokerr(merr, ParseError.TooManyTokens, t);
                class.inverse = inverse_class;
                class.possible = try generate_class_string(allocator, stmp1, stmp2, merr);
            }
        },
        else => {
            return tokerr(merr, ParseError.InvalidToken, t);
        },
    }

    p.data = .{ .class = class };
    p.next = try parse_tokens(allocator, toks, merr);
    return p;
}

fn parse_macro(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const p = try allocator.create(patterns.Pattern);
    var mg = try allocator.create(patterns.MatchGroup);
    p.data = .{ .match = mg };
    mg.pattern = null;
    mg.next = null;
    var endn: usize = undefined;

    _ = toks.next_token();
    const maybe_macpattern = try parse_tokens(allocator, toks, merr);
    const macpattern = maybe_macpattern orelse
        return doerr(merr, ParseError.IncompleteTerm); // ???
    defer macpattern.destroy(allocator);

    var t = toks.next_token() orelse
        return doerr(merr, ParseError.IncompleteTerm);
    if (t.typ != .range_start)
        return tokerr(merr, ParseError.InvalidToken, t);

    t = toks.next_token() orelse
        return doerr(merr, ParseError.IncompleteTerm);
    if (t.typ != .number)
        return tokerr(merr, ParseError.InvalidToken, t);
    const startn = try std.fmt.parseInt(usize, t.string, 10);

    t = toks.next_token() orelse
        return doerr(merr, ParseError.IncompleteTerm);
    if (t.typ == .range_end) {
        endn = startn;
    } else {
        if (t.typ != .range_next_field)
            return tokerr(merr, ParseError.InvalidToken, t);

        t = toks.next_token() orelse
            return doerr(merr, ParseError.IncompleteTerm);
        if (t.typ != .number)
            return tokerr(merr, ParseError.InvalidToken, t);
        endn = try std.fmt.parseInt(usize, t.string, 10);

        t = toks.next_token() orelse
            return doerr(merr, ParseError.IncompleteTerm);
        if (t.typ != .range_end)
            return tokerr(merr, ParseError.InvalidToken, t);
    }

    if (startn > endn) {
        const ce = ParseError.InvalidRange;
        const err = merr orelse return ce;
        err.msg = try std.fmt.allocPrint(
            allocator.*,
            "error: {!}: startn:{d} > endn:{d}",
            .{ ce, startn, endn },
        );
        err.err = ce;
        err.token = null;
        return ce;
    }

    if (startn == endn) {
        mg.pattern = try patterns.nCloneCopies(allocator, macpattern, startn);
        mg.next = null;
        p.next = try parse_tokens(allocator, toks, merr);
        return p;
    }

    var i = startn;
    while (i <= endn) : (i += 1) {
        const np = if (i == 0) null else try patterns.nCloneCopies(allocator, macpattern, i);
        if (i == startn) {
            mg.pattern = np;
            mg.next = null;
        } else {
            mg.next = try allocator.create(patterns.MatchGroup);
            mg = mg.next orelse unreachable;
            mg.pattern = np;
            mg.next = null;
        }
    }

    p.next = try parse_tokens(allocator, toks, merr);
    return p;
}

fn parse_match_set(
    allocator: *std.mem.Allocator,
    toks: *tokenizer.Tokens,
    merr: ?*ErrorInfo,
) ParseError!?*patterns.Pattern {
    const p = try allocator.create(patterns.Pattern);
    var mmg: ?*patterns.MatchGroup = null;
    const mhead = try allocator.create(patterns.MatchGroup);

    while (true) {
        const t = toks.next_token() orelse
            return doerr(merr, ParseError.IncompleteTerm);
        switch (t.typ) {
            .match_set_start, .match_set_next => {
                const mp = try parse_tokens(allocator, toks, merr);
                if (mmg) |mg| {
                    if (mg.next) |_|
                        return doerr2(merr, ParseError.BadList, "mg.next should be null");
                    mg.next = try allocator.create(patterns.MatchGroup);
                    mmg = mg.next;
                } else {
                    mmg = mhead;
                }
                // mmg is good by here
                const mg = mmg orelse
                    return doerr2(merr, ParseError.BadList, "mg should be non-null");
                mg.pattern = mp;
                mg.next = null;
            },
            .match_set_end => {
                break;
            },
            else => {
                return tokerr(merr, ParseError.InvalidToken, t);
            },
        }
    }

    p.data = .{ .match = mhead };
    p.next = try parse_tokens(allocator, toks, merr);
    return p;
}

// test_output strings are from cesmglob. they're likely correct

test "basic parser" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello12345world";
    const test_output = "hello12345world";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser question marks" {
    var allocator = std.heap.page_allocator;
    const test_input = "three?3four?4ten?10";
    const test_output = "three???four????ten??????????";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[0-9]";
    const test_output = "[0123456789]";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser inverse class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[~0-9]";
    const test_output = "[~0123456789]";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser letter class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[a-z][A-Z]";
    const test_output = "[abcdefghijklmnopqrstuvwxyz][ABCDEFGHIJKLMNOPQRSTUVWXYZ]";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser complete class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[A-z]";
    const test_output = "[ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz]";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser class with wildcard" {
    var allocator = std.heap.page_allocator;
    const test_input = "[fm]*.zig";
    const test_output = "[fm]*.zig";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser macro" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello%test<3-5>?12";
    const test_output = "hello(testtesttest|testtesttesttest|testtesttesttesttest)????????????";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser qmark macros" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello?<3-4>";
    const test_output = "hello(???|????)";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser advanced macro" {
    var allocator = std.heap.page_allocator;
    const test_input = "%[0-9]<2-5>";
    const test_output = "([0123456789][0123456789]|[0123456789][0123456789][0123456789]|[0123456789][0123456789][0123456789][0123456789]|[0123456789][0123456789][0123456789][0123456789][0123456789])";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser advanced macro 2" {
    var allocator = std.heap.page_allocator;
    const test_input = "%(1|2|3)<3-5>";
    const test_output = "((1|2|3)(1|2|3)(1|2|3)|(1|2|3)(1|2|3)(1|2|3)(1|2|3)|(1|2|3)(1|2|3)(1|2|3)(1|2|3)(1|2|3))";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "parser match set" {
    var allocator = std.heap.page_allocator;
    const test_input = "(1|2|3|4|5)";
    const test_output = "(1|2|3|4|5)";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "advanced parser" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello12345(%[0-9]<10-12>|is|?12|test)";
    const test_output = "hello12345(([0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]|[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789]|[0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789][0123456789])|is|????????????|test)";
    var merr = ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    const mp = parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    };

    if (mp) |p| {
        const res = try p.toString(&allocator);
        try std.testing.expect(std.mem.eql(u8, res, test_output));
    } else {
        return error.NullPattern;
    }
}

test "error parser test" {
    var allocator = std.heap.page_allocator;
    const test_input = "hello12345(is|?12|test";

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    _ = parse_tokens(&allocator, toks, null) catch {
        return;
    };

    return error.DidNotFail;
}

test "error parser test invalid token" {
    var allocator = std.heap.page_allocator;
    const test_input = "%hello<12->";

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    _ = parse_tokens(&allocator, toks, null) catch {
        return;
    };

    return error.DidNotFail;
}

test "error parser test invalid class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[please-fail]";

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    _ = parse_tokens(&allocator, toks, null) catch {
        return;
    };

    return error.DidNotFail;
}

test "error parser test backwards class" {
    var allocator = std.heap.page_allocator;
    const test_input = "[z-a]";

    const toks = try tokenizer.tokenize_string(&allocator, test_input);

    _ = parse_tokens(&allocator, toks, null) catch {
        return;
    };

    return error.DidNotFail;
}
