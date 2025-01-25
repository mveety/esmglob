const std = @import("std");
const patterns = @import("patterns.zig");

pub const MatchError = error{
    NoMatch,
    InvalidPattern,
    OutOfMemory,
    EmptyPattern,
};

fn string_match(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
    dirmatch: bool,
) MatchError!usize {
    _ = mparent;
    _ = dirmatch;
    var i: usize = 0;

    if (s.len < p.data.string.string.len)
        return MatchError.NoMatch;
    while (i < s.len and i < p.data.string.string.len) : (i += 1) {
        if (s[i] != p.data.string.string[i])
            return MatchError.NoMatch;
    }
    return i;
}

fn class_match(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
    dirmatch: bool,
) MatchError!usize {
    _ = mparent;
    _ = dirmatch;
    var i: usize = 0;

    while (i < p.data.class.possible.len) : (i += 1) {
        if (s[0] == p.data.class.possible[i]) {
            if (!p.data.class.inverse) return 1;
        }
    }
    if (p.data.class.inverse) return 1 else return MatchError.NoMatch;
}

fn wildcard_match(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
    dirmatch: bool,
) MatchError!usize {
    var bestmatch: usize = 0;
    var hasmatch = false;
    if (p.data.wildcard.single) {
        if (s.len >= p.data.wildcard.repeat)
            return p.data.wildcard.repeat;
        return MatchError.NoMatch;
    } else {
        if (p.next) |pn| {
            var i: usize = 1;
            while (i < s.len) : (i += 1) {
                // same is true here as below. zig makes this easy to spot.
                const rest = do_match1(s[i..], pn, null, dirmatch) catch |err| {
                    if (err == MatchError.NoMatch) continue;
                    return err;
                };
                if (rest + i >= s.len) return i;
                hasmatch = true;
                bestmatch = i;
            }
            if (hasmatch) return bestmatch;
            return MatchError.NoMatch;
        } else {
            if (mparent) |parent| {
                var i: usize = 1;
                while (i < s.len) : (i += 1) {
                    const rest = do_match1(s[i..], parent, null, dirmatch) catch |err| {
                        if (err == MatchError.NoMatch) continue;
                        return err;
                    };
                    if (rest + i >= s.len) return i;
                    hasmatch = true;
                    bestmatch = i;
                }
                if (hasmatch) return bestmatch;
                return MatchError.NoMatch;
            } else {
                return s.len;
            }
        }
    }
}

fn matchgroup_match(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
    dirmatch: bool,
) MatchError!usize {
    _ = mparent;
    var matchgroup: ?*patterns.MatchGroup = p.data.match;
    var result: usize = 0;
    var hasmatch = false;

    while (matchgroup) |mg| : (matchgroup = mg.next) {
        const tp = mg.pattern orelse {
            // empty pattern
            hasmatch = true;
            continue;
        };
        const res = do_match1(s, tp, p.next, dirmatch) catch |err| {
            if (err != MatchError.NoMatch) return err;
            continue;
        }; // there's an easy optimization here
        if (p.next) |pnext| {
            _ = do_match1(s[res..], pnext, null, dirmatch) catch |err| {
                if (err != MatchError.NoMatch) return err;
                continue;
            };
        }
        hasmatch = true;
        if (res > result) result = res;
    }
    if (hasmatch) return result else return MatchError.NoMatch;
}

fn isSlash(mp: ?*patterns.Pattern) bool {
    if (mp) |p| {
        return switch (p.data) {
            else => false,
            .string => if (p.data.string.string[0] == '/') true else false,
        };
    }
    return false;
}

fn do_match1(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
    dirmatch: bool,
) MatchError!usize {
    var i: usize = 0;
    var pattern = p;
    if (s.len == 0) return MatchError.NoMatch;
    while (i < s.len) {
        const matchlen = try switch (pattern.data) {
            .string => string_match(s[i..], pattern, mparent, dirmatch),
            .class => class_match(s[i..], pattern, mparent, dirmatch),
            .wildcard => wildcard_match(s[i..], pattern, mparent, dirmatch),
            .match => matchgroup_match(s[i..], pattern, mparent, dirmatch),
        };
        i += matchlen;
        pattern = pattern.next orelse return i;
    }
    if (dirmatch) {
        if (isSlash(pattern)) return i;
    }
    if (pattern.next) |_| return MatchError.NoMatch;
    return i;
}

pub fn do_match(
    s: []const u8,
    p: *patterns.Pattern,
    mparent: ?*patterns.Pattern,
) MatchError!usize {
    return do_match1(s, p, mparent, false);
}

pub fn dirMatch(s: []const u8, p: *patterns.Pattern) MatchError!usize {
    return do_match1(s, p, null, true);
}

test "matching basic test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "hello";
    const test_string = "helloworld";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching empty string test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "hello";
    const test_string = "";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = do_match(test_string, pattern, null) catch |err| {
        if (err != MatchError.NoMatch) return err;
        return;
    };
    return error.GoodMatch;
}

test "matching wildcard test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "h*w";
    const test_string = "helloworld";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching wildcard fail test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "h*w";
    const test_string = "please fail";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = do_match(test_string, pattern, null) catch |err| {
        if (err != MatchError.NoMatch) return err;
        return;
    };
    return error.GoodMatch;
}

test "matching wildcard only" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "*";
    const test_string = "this should pass";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching match group test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "(hello|goodnight)*";
    const test_string = "hello world";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching match group with ending wildcard test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "(f*|m*).zig";
    const test_string = "filter.zig";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching match group fail test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "(please|fail)thankyou";
    const test_string = "please fail thankyou";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = do_match(test_string, pattern, null) catch |err| {
        if (err != MatchError.NoMatch) return err;
        return;
    };
    return error.GoodMatch;
}

test "matching qmark test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "?5 world";
    const test_string = "hello world";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching qmark fail test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "?5 world";
    const test_string = "goodbye world";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = do_match(test_string, pattern, null) catch |err| {
        if (err != MatchError.NoMatch) return err;
        return;
    };
    return error.GoodMatch;
}

test "matching class and macro test 1" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "[0-9][0-9][0-9][0-9] stuff";
    const test_string = "1234 stuff";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching class and macro test 2" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "%[0-9]<3-5> stuff";
    const test_string = "5678 stuff";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching class and macro test 3" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "[fm]*.zig";
    const test_string = "matching.zig";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try do_match(test_string, pattern, null);
}

test "matching class and macro fail test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "%[0-9]<3-5> stuff";
    const test_string = "abcd stuff";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = do_match(test_string, pattern, null) catch |err| {
        if (err != MatchError.NoMatch) return err;
        return;
    };
    return error.GoodMatch;
}

test "matching directory test" {
    const tokenizer = @import("tokenizer.zig");
    const parser = @import("parser.zig");

    var allocator = std.heap.page_allocator;
    const test_glob = "stuff/*.zig";
    const test_string = "stuff";
    var merr = parser.ErrorInfo.new(&allocator);

    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
        merr.print();
        return err;
    } orelse return error.NullPattern;

    _ = try dirMatch(test_string, pattern);
}

//test "matching directory test match group" {
//    const tokenizer = @import("tokenizer.zig");
//    const parser = @import("parser.zig");
//
//    var allocator = std.heap.page_allocator;
//    const test_glob = "(stuff|things)/*.zig";
//    const test_string = "things";
//    var merr = parser.ErrorInfo.new(&allocator);
//
//    const toks = try tokenizer.tokenize_string(&allocator, test_glob);
//    const pattern = parser.parse_tokens(&allocator, toks, &merr) catch |err| {
//        merr.print();
//        return err;
//    } orelse return error.NullPattern;
//
//    const match_len = try dirMatch(test_string, pattern);
//}
//
