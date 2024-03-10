const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const Token = enum {
    // Keywords.
    kw_mod,
    kw_pub,
    kw_use,
    kw_struct,
    kw_enum,
    kw_const,
    kw_fn,
    kw_where,
    kw_trait,
    kw_impl,
    kw_dyn,
    kw_while,
    kw_for,
    kw_if,
    kw_else,
    kw_match,
    kw_let,
    kw_mut,
    kw_return,

    // Operators.
    @"=>",
    @"::",
    @":",
    @"..=",
    @"..",
    @"==",
    @"=",
    @"{",
    @"}",
    @"(",
    @")",
    @"[",
    @"]",
    @"->",
    @"'", // Or should we instead add `d_lifetime`?
    @"#",
    @"<=",
    @"<",
    @">=",
    @">",
    @".",
    @"|",
    @"!", // For macros.
    @"&",
    @",",
    @";",
    @"*",
    @"/",
    @"+",
    @"-",

    // Tokens with associated data.
    d_string,
    d_number,
    d_char,
    d_ident,
};

const Operator = struct {
    token: Token,
    str: []const u8,
};
const operators = compute_operators: {
    var i = 0;
    for (@typeInfo(Token).Enum.fields) |f| {
        if (!std.mem.startsWith(u8, f.name, "kw_") and !std.mem.startsWith(u8, f.name, "d_")) {
            i += 1;
        }
    }

    var arr: [i]Operator = undefined;
    i = 0;
    for (@typeInfo(Token).Enum.fields) |f| {
        if (!std.mem.startsWith(u8, f.name, "kw_") and !std.mem.startsWith(u8, f.name, "d_")) {
            arr[i] = .{ .token = @enumFromInt(f.value), .str = f.name };
            i += 1;
        }
    }

    break :compute_operators arr;
};
fn tokenToOperatorStr(token: Token) ?[]const u8 {
    for (operators) |op| {
        if (op.token == token)
            return op.str;
    }
    return null;
}

const Keyword = struct {
    token: Token,
    str: []const u8,
};
const keywords = compute_keywords: {
    var i = 0;
    for (@typeInfo(Token).Enum.fields) |f| {
        if (std.mem.startsWith(u8, f.name, "kw_")) {
            i += 1;
        }
    }

    var arr: [i]Keyword = undefined;
    i = 0;
    for (@typeInfo(Token).Enum.fields) |f| {
        const prefix = "kw_";
        if (std.mem.startsWith(u8, f.name, prefix)) {
            arr[i] = .{ .token = @enumFromInt(f.value), .str = f.name[prefix.len..] };
            i += 1;
        }
    }

    break :compute_keywords arr;
};
fn tokenToKeywordStr(token: Token) ?[]const u8 {
    for (keywords) |kw| {
        if (kw.token == token)
            return kw.str;
    }
    return null;
}

const TokenizerError = error{
    MultilineStringsNotSupported,
    ClosingQuoteMissing,
    UnrecognizedToken,
};

/// Used in `tokenize`.
fn getLineComment(data: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data, "//")) {
        if (std.mem.indexOfScalar(u8, data, '\n')) |i| {
            // Comment includes trailing new line.
            return data[0 .. i + 1];
        } else {
            // Line comment continues to the end of data.
            return data;
        }
    }
    return null;
}

/// Used in `tokenize` and `Match.parsePattern`.
fn getOperator(data: []const u8) ?Operator {
    var found: ?Operator = null;

    // Search for the longest prefix.
    for (operators) |o| {
        if (std.mem.startsWith(u8, data, o.str)) {
            if (found) |f| {
                if (f.str.len < o.str.len) {
                    found = o;
                }
            } else {
                found = o;
            }
        }
    }

    return found;
}

/// Used in `tokenize` and `Match.parsePattern`.
fn getIdentifier(data: []const u8) ?[]const u8 {
    if (std.ascii.isAlphabetic(data[0]) or data[0] == '_') {
        var i: usize = 1;
        while (i < data.len and (std.ascii.isAlphanumeric(data[i]) or data[i] == '_')) : (i += 1) {}
        return data[0..i];
    }
    return null;
}

/// Used in `tokenize` and `Match.parsePattern`.
fn isIdentifierKeyword(identifier: []const u8) ?Token {
    for (keywords) |k| {
        if (std.mem.eql(u8, identifier, k.str)) {
            return k.token;
        }
    }
    return null;
}

/// Used in `tokenize`.
fn getString(data: []const u8) TokenizerError!?[]const u8 {
    if (data[0] == '"') {
        var i: usize = 1;
        var closed = false;
        while (!closed and i < data.len) {
            if (data[i] == '\\') {
                // `while` loop condition checks if we're still in
                // the slice so we can safely increment `i` by 2.
                // Incrementing by 2 hopefully works even for escape sequences longer than 2
                // because they don't contain backslash or double quote in the middle.
                i += 2;
            } else if (data[i] == '"') {
                i += 1;
                closed = true;
            } else {
                i += 1;
            }
        }

        if (!closed)
            return TokenizerError.ClosingQuoteMissing;
        if (std.mem.indexOfScalar(u8, data[0..i], '\n')) |_|
            return TokenizerError.MultilineStringsNotSupported;
        return data[0..i];
    }
    return null;
}

/// Used in `tokenize` to tokenize both integers and decimal numbers.
fn getNumber(data: []const u8) ?[]const u8 {
    const isDigit = std.ascii.isDigit;
    // CONSIDER: Parse initial sign as a part of the number?
    if (isDigit(data[0])) {
        var i: usize = 1;
        var seenDot = false;
        var seenE = false;

        while (i < data.len) {
            const c1 = data[i];
            const c2 = if (i + 1 < data.len) data[i + 1] else 0;
            const c3 = if (i + 2 < data.len) data[i + 2] else 0;

            if (isDigit(c1)) {
                i += 1;
            } else if (c1 == '.' and !seenDot and !seenE and isDigit(c2)) {
                seenDot = true;
                i += 2;
            } else if (c1 == 'e' and !seenE) {
                if (isDigit(c2)) {
                    seenE = true;
                    i += 2;
                } else if ((c2 == '+' or c2 == '-') and isDigit(c3)) {
                    seenE = true;
                    i += 3;
                } else {
                    break; // `e` will be part of the next token.
                }
            } else {
                break;
            }
        }
        return data[0..i];
    }
    return null;
}

/// Used in `tokenize`.
fn getChar(data: []const u8) ?[]const u8 {
    // If it has less than 3 bytes then it can't contain char.
    if (data.len >= 3 and data[0] == '\'') {
        if (data[1] == '\\') {
            // We have char for sure because lifetimes don't contain slashes.

            if (data[2] == '\'')
                // Either escaped single quote or something invalid.
                return if (data.len >= 4 and data[3] == '\'') data[0..4] else null;

            if (std.mem.indexOfScalarPos(u8, data, 2, '\'')) |i| {
                // Escape sequence ends with single quote.
                return data[0 .. i + 1];
            }
        } else {
            // Not sure if it's char or lifetime.
            // We need to read one utf-8 code point and if the byte after it
            // is single quote then we have single quoted char.
            // Otherwise we have lifetime.

            // zig fmt: off
            const codepoint_len: usize =
                if (data[1] & 0b1000_0000 == 0) 1
                else if (data[1] & 0b1110_0000 == 0b1100_0000) 2
                else if (data[1] & 0b1111_0000 == 0b1110_0000) 3
                else if (data[1] & 0b1111_1000 == 0b1111_0000) 4
                else return null;
            // zig fmt: on

            const i = codepoint_len + 1;

            if (i < data.len and data[i] == '\'') return data[0 .. i + 1];
        }
    }
    return null;
}

const LenAndData = struct {
    len: usize,
    data: []const u8,
};

fn LenAndMultiData(n: comptime_int) type {
    return struct {
        len: usize,
        data: [n][]const u8,
    };
}

const CommentIndex = usize; // Index into `comments`.
const CommentRange = struct { from: CommentIndex, to_excl: CommentIndex };

const Match = struct {
    const Pattern = struct {
        tokens: []const Token,
        // Names of struct fields into which token data will be captured.
        capture_field_names: []const ?[]const u8,
        // Number of non-null `capture_field_names`.
        capture_count: usize,
    };

    /// Used to process `Toks.match` patterns.
    /// These patterns are used to match against Rust tokens.
    /// Patterns use operators and keywords from Rust to match themselves
    /// and identifiers to match identifiers or strings or numbers.
    /// By default identifier matches identifier but optional kinds `:str`, `:num` and `:char`
    /// after the identifier make it match string or number or char.
    ///
    /// Identifiers which don't start by underscore capture `token_data`.
    /// Structs returned by `Toks.match` have fields with captured `token_data`.
    /// These fields are named after identifiers in the original pattern.
    fn parsePattern(comptime pattern: []const u8) Pattern {
        @setEvalBranchQuota(2000);
        comptime var n = 0;
        comptime var tokens = [1]Token{undefined} ** pattern.len;
        comptime var capture_field_names = [1]?[]const u8{null} ** pattern.len;
        comptime var capture_count = 0;
        comptime var data = pattern;
        while (data.len > 0) {
            if (data[0] == ' ') {
                data = data[1..];
            } else if (data[0] == '\n') {
                @compileError("Pattern must not contain new lines");
            } else if (getOperator(data)) |operator| {
                data = data[operator.str.len..];
                tokens[n] = operator.token;
                n += 1;
            } else if (getIdentifier(data)) |identifier| {
                data = data[identifier.len..];
                if (isIdentifierKeyword(identifier)) |keyword| {
                    tokens[n] = keyword;
                    n += 1;
                } else {
                    tokens[n] = .d_ident;
                    // Optional token type.
                    // There must not be any spaces between colon and token kind.
                    if (std.mem.startsWith(u8, data, ":str")) {
                        data = data[4..];
                        tokens[n] = .d_string;
                    } else if (std.mem.startsWith(u8, data, ":num")) {
                        data = data[4..];
                        tokens[n] = .d_number;
                    } else if (std.mem.startsWith(u8, data, ":char")) {
                        data = data[5..];
                        tokens[n] = .d_char;
                    } else if (std.mem.startsWith(u8, data, ":")) {
                        // Unknown token kinds are not allowed.
                        @panic("Unknown token kind or are you missing a space before colon?");
                    }

                    // Leading underscore signifies that value shall not be captured.
                    if (std.mem.startsWith(u8, identifier, "_")) {
                        // No capturing in this case.
                    } else {
                        capture_field_names[n] = identifier;
                        capture_count += 1;
                    }

                    n += 1;
                }
            } else {
                @compileError("Unrecognized pattern part: " ++ data);
            }
        }
        return .{
            .tokens = tokens[0..n],
            .capture_field_names = capture_field_names[0..n],
            .capture_count = capture_count,
        };
    }

    fn Result(comptime pattern: []const u8) type {
        const pat = parsePattern(pattern);
        var n = 0;
        var fields: [pat.capture_count + 1]std.builtin.Type.StructField = undefined;

        fields[n] = std.builtin.Type.StructField{
            .name = "len",
            .type = usize,
            .default_value = null,
            .is_comptime = false,
            .alignment = 0,
        };
        n += 1;
        for (pat.capture_field_names) |capture_field_name| {
            if (capture_field_name) |field_name| {
                fields[n] = std.builtin.Type.StructField{
                    .name = field_name ++ "",
                    .type = []const u8,
                    .default_value = null,
                    .is_comptime = false,
                    .alignment = 0,
                };
                n += 1;
            }
        }

        if (n != pat.capture_count + 1)
            @panic("Unexpected number of fields in struct");

        return @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }
};

const Toks = struct {
    tokens: []Token,
    token_data: []?[]const u8,
    comments_before_token: []?CommentRange,
    comment_after_token: []?CommentIndex,
    comments: [][]const u8,

    fn match(self: Toks, i: usize, comptime pattern: []const u8) ?Match.Result(pattern) {
        const pat = comptime Match.parsePattern(pattern);
        if (std.mem.startsWith(Token, self.tokens[i..], pat.tokens)) {
            var result: Match.Result(pattern) = undefined;
            result.len = pat.tokens.len;
            inline for (pat.capture_field_names, 0..) |capture_field_name, pat_i| {
                if (capture_field_name) |field_name| {
                    if (self.token_data[i + pat_i]) |data| {
                        @field(result, field_name) = data;
                    } else {
                        @panic("No value captured for field " ++ field_name);
                    }
                }
            }
            return result;
        }
        return null;
    }

    fn matchEql(self: Toks, i: usize, comptime pattern: []const u8, comptime expected: anytype) ?Match.Result(pattern) {
        const ti = switch (@typeInfo(@TypeOf(expected))) {
            .Struct => |s| s,
            else => @compileError("Type of expected is not struct"),
        };

        if (self.match(i, pattern)) |result| {
            inline for (ti.fields) |field| {
                if (!std.mem.eql(u8, @field(result, field.name), @field(expected, field.name)))
                    return null;
            }
            return result;
        }
        return null;
    }

    fn startsWith(self: Toks, i: usize, needle: []const Token) ?usize {
        if (std.mem.startsWith(Token, self.tokens[i..], needle))
            return needle.len
        else
            return null;
    }

    fn startsWithAny(self: Toks, i: usize, needles: []const []const Token) ?usize {
        for (needles) |needle| {
            if (self.startsWith(i, needle)) |len|
                return len;
        }
        return null;
    }

    fn startsWithAndGetData(self: Toks, i: usize, needle: []const Token) ?LenAndData {
        if (std.mem.startsWith(Token, self.tokens[i..], needle)) {
            for (self.token_data[i..][0..needle.len]) |data| {
                if (data) |d|
                    return .{ .len = needle.len, .data = d };
            }
            return null;
        } else {
            return null;
        }
    }

    fn startsWithAnyAndGetData(self: Toks, i: usize, needles: []const []const Token) ?LenAndData {
        for (needles) |needle| {
            if (self.startsWithAndGetData(i, needle)) |ld|
                return ld;
        }
        return null;
    }

    // CONSIDER: Infer `n` from comptime `needle`.
    //           Or replace this function by `match`?
    fn startsWithAndGetMultiData(self: Toks, n: comptime_int, i: usize, needle: []const Token) ?LenAndMultiData(n) {
        if (self.startsWith(i, needle)) |len| {
            var found: usize = 0;
            var result: LenAndMultiData(n) = .{ .len = len, .data = undefined };
            for (self.token_data[i..][0..needle.len]) |data| {
                if (data) |d| {
                    result.data[found] = d;
                    found += 1;
                    if (found == n)
                        return result;
                }
            }
            return null;
        } else {
            return null;
        }
    }

    // Returned token count does not include stop token.
    fn genericBracketedCountUntilAny(
        self: Toks,
        i: usize,
        opening: []const Token,
        closing: []const Token,
        stop: []const Token,
    ) ParserError!usize {
        const tokens = self.tokens[i..];
        var count: usize = 0;
        var open: usize = 0; // We don't check whether closing bracket matches opening.
        while (count < tokens.len) : (count += 1) {
            const t = tokens[count];

            // Because `stop` can contain brackets following if statement must be before switch.
            if (open == 0) {
                if (std.mem.indexOfScalar(Token, stop, t)) |_| {
                    return count;
                }
            }

            if (std.mem.indexOfScalar(Token, opening, t)) |_| {
                open += 1;
            } else if (std.mem.indexOfScalar(Token, closing, t)) |_| {
                if (open == 0)
                    return ParserError.TooManyClosingBrackets
                else
                    open -= 1;
            }
        }
        return ParserError.StopTokenNotFound;
    }

    /// Parses string with stop tokens into a slice of stop tokens.
    /// String may contain operators and keywords. Additionally it may contain
    /// `ident` identifier which is translated to `.d_ident` token.
    fn parseStop(comptime stop: []const u8) []const Token {
        comptime var n = 0;
        comptime var tokens = [1]Token{undefined} ** stop.len;
        comptime var data = stop;
        while (data.len > 0) {
            if (data[0] == ' ') {
                data = data[1..];
            } else if (data[0] == '\n') {
                @compileError("Stop must not contain new lines");
            } else if (getOperator(data)) |operator| {
                data = data[operator.str.len..];
                tokens[n] = operator.token;
                n += 1;
            } else if (getIdentifier(data)) |identifier| {
                data = data[identifier.len..];
                if (isIdentifierKeyword(identifier)) |keyword| {
                    tokens[n] = keyword;
                    n += 1;
                } else if (std.mem.eql(u8, identifier, "ident")) {
                    tokens[n] = .d_ident;
                } else {
                    @compileError("Unrecognized identifier: " ++ identifier);
                }
            } else {
                @compileError("Unrecognized pattern part: " ++ data);
            }
        }
        return tokens[0..n];
    }

    /// Determines a length of a type starting at `i`-th token and ending before the first stop token
    /// which is not enclosed in brackets. Following brackets are recognized:
    /// `<` and `>`, `[` and `]`, `(` and `)`, `{` and `}`.
    ///
    /// `stop` is a string with stop tokens. We parse this string during comptime by `parseStop`.
    /// Writing stop tokens in a single string is more ergonomic than writing a slice of tokens.
    fn typeLen(self: Toks, i: usize, comptime stop: []const u8) ParserError!usize {
        const stop_tokens = comptime parseStop(stop);
        return self.genericBracketedCountUntilAny(
            i,
            &.{ .@"(", .@"[", .@"{", .@"<" },
            &.{ .@")", .@"]", .@"}", .@">" },
            stop_tokens,
        );
    }

    /// This is similar to `typeLen`. The only difference is that `typeLen` recognizes angle
    /// brackets `<` and `>` whereas `expressionLen` does not.
    /// The reason is that `<` in expression may mean lower than operator
    /// and `>` in expression may mean greater than operator. So not every `<` is followed by `>`.
    fn expressionLen(self: Toks, i: usize, comptime stop: []const u8) ParserError!usize {
        const stop_tokens = comptime parseStop(stop);
        return self.genericBracketedCountUntilAny(
            i,
            &.{ .@"(", .@"[", .@"{" },
            &.{ .@")", .@"]", .@"}" },
            stop_tokens,
        );
    }

    /// Restricts `self` to the first `token_count` tokens.
    fn restrict(self: Toks, token_count: usize) Toks {
        return .{
            .tokens = self.tokens[0..token_count],
            .token_data = self.token_data[0..token_count],
            .comments_before_token = self.comments_before_token[0 .. token_count + 1],
            .comment_after_token = self.comment_after_token[0..token_count],
            .comments = self.comments,
        };
    }

    fn deinit(self: *const Toks, allocator: Allocator) void {
        allocator.free(self.tokens);
        allocator.free(self.token_data);
        allocator.free(self.comments_before_token);
        allocator.free(self.comment_after_token);
        allocator.free(self.comments);
    }
};

const TokenizerState = struct {
    tokens: std.ArrayList(Token),
    // Contains same number of items as `tokens`.
    token_data: std.ArrayList(?[]const u8),
    // Contains one more item than `tokens`.
    comments_before_token: std.ArrayList(?CommentRange),
    // Contains same number of items as `tokens`.
    comment_after_token: std.ArrayList(?CommentIndex),
    comments: std.ArrayList([]const u8),

    fn init(allocator: Allocator) Allocator.Error!TokenizerState {
        var comments_before_token = std.ArrayList(?CommentRange).init(allocator);
        errdefer comments_before_token.deinit();

        // Ensure that `comments_before_token` contains one more item than `tokens`.
        try comments_before_token.append(null);

        return .{
            .tokens = std.ArrayList(Token).init(allocator),
            .token_data = std.ArrayList(?[]const u8).init(allocator),
            .comments_before_token = comments_before_token,
            .comment_after_token = std.ArrayList(?CommentIndex).init(allocator),
            .comments = std.ArrayList([]const u8).init(allocator),
        };
    }

    fn addToken(self: *TokenizerState, t: Token) Allocator.Error!void {
        try self.tokens.append(t);
        try self.token_data.append(null);
        try self.comments_before_token.append(null);
        try self.comment_after_token.append(null);
    }

    fn addTokenWithData(self: *TokenizerState, t: Token, data: []const u8) Allocator.Error!void {
        try self.tokens.append(t);
        try self.token_data.append(data);
        try self.comments_before_token.append(null);
        try self.comment_after_token.append(null);
    }

    fn toToks(self: *TokenizerState) Allocator.Error!Toks {
        const tokens = try self.tokens.toOwnedSlice();
        errdefer self.tokens.allocator.free(tokens);

        const token_data = try self.token_data.toOwnedSlice();
        errdefer self.token_data.allocator.free(token_data);

        const comments_before_token = try self.comments_before_token.toOwnedSlice();
        errdefer self.comments_before_token.allocator.free(comments_before_token);

        const comment_after_token = try self.comment_after_token.toOwnedSlice();
        errdefer self.comment_after_token.allocator.free(comment_after_token);

        const comments = try self.comments.toOwnedSlice();
        errdefer self.comments.allocator.free(comments);

        return .{
            .tokens = tokens,
            .token_data = token_data,
            .comments_before_token = comments_before_token,
            .comment_after_token = comment_after_token,
            .comments = comments,
        };
    }

    fn deinit(self: *TokenizerState) void {
        self.tokens.deinit();
        self.token_data.deinit();
        self.comments_before_token.deinit();
        self.comment_after_token.deinit();
        self.comments.deinit();
    }
};

fn tokenize(
    source_code: []const u8,
    allocator: Allocator,
) (Allocator.Error || TokenizerError)!Toks {
    var s = try TokenizerState.init(allocator);
    defer s.deinit();
    var data = source_code;
    var token_count_when_line_started: usize = 0; // Used when processing line comments.

    while (data.len > 0) {
        if (data[0] == ' ') {
            data = data[1..];
        } else if (data[0] == '\n') {
            token_count_when_line_started = s.tokens.items.len;
            data = data[1..];
        } else if (getLineComment(data)) |comment| {
            try s.comments.append(comment);

            if (token_count_when_line_started == s.tokens.items.len) {
                // The line with the line comment does not contain any other token
                // before the line comment. So we assume that the line comment belongs
                // to the token which follows which hasn't been yet tokenized.

                if (s.comments_before_token.items[s.tokens.items.len]) |existing_range| {
                    // Existing comment range must end at the previous comment.
                    std.debug.assert(existing_range.to_excl == s.comments.items.len - 1);

                    s.comments_before_token.items[s.tokens.items.len] = .{
                        .from = existing_range.from,
                        .to_excl = s.comments.items.len,
                    };
                } else {
                    s.comments_before_token.items[s.tokens.items.len] = .{
                        .from = s.comments.items.len - 1,
                        .to_excl = s.comments.items.len,
                    };
                }
            } else {
                // The line with the line comment contains a token before the line comment.
                // We assume that the line comment is associated with this token.

                s.comment_after_token.items[s.tokens.items.len - 1] = s.comments.items.len - 1;
            }

            // Line comments ended with newline
            // (or end of file in which case `token_count_when_line_started` value doesn't matter).
            token_count_when_line_started = s.tokens.items.len;
            data = data[comment.len..];
        } else if (getIdentifier(data)) |identifier| {
            data = data[identifier.len..];
            if (isIdentifierKeyword(identifier)) |keyword| {
                try s.addToken(keyword);
            } else {
                try s.addTokenWithData(.d_ident, identifier);
            }
        } else if (try getString(data)) |string| {
            data = data[string.len..];
            try s.addTokenWithData(.d_string, string);
        } else if (getNumber(data)) |number| {
            data = data[number.len..];
            try s.addTokenWithData(.d_number, number);
        } else if (getChar(data)) |char| {
            // `getChar` must be before `getOperator`.
            data = data[char.len..];
            try s.addTokenWithData(.d_char, char);
        } else if (getOperator(data)) |operator| {
            data = data[operator.str.len..];
            try s.addToken(operator.token);
        } else {
            return TokenizerError.UnrecognizedToken;
        }
    }

    return try s.toToks();
}

const FieldInfo = struct {
    name: []const u8,
};

const FieldIndex = usize;

const StructInfo = struct {
    public: bool,
    name: []const u8,
    fields_from: FieldIndex,
    fields_to_excl: FieldIndex,
};

const Structs = struct {
    structs: []StructInfo,
    fields: []FieldInfo,

    fn deinit(self: *const Structs, allocator: Allocator) void {
        allocator.free(self.structs);
        allocator.free(self.fields);
    }
};

const StructReaderSate = struct {
    structs: std.ArrayList(StructInfo),
    fields: std.ArrayList(FieldInfo),

    fn init(allocator: Allocator) StructReaderSate {
        return .{
            .structs = std.ArrayList(StructInfo).init(allocator),
            .fields = std.ArrayList(FieldInfo).init(allocator),
        };
    }

    fn toStructs(self: *StructReaderSate) !Structs {
        const structs = try self.structs.toOwnedSlice();
        errdefer self.structs.allocator.free(structs);

        const fields = try self.fields.toOwnedSlice();
        errdefer self.fields.allocator.free(fields);

        return .{
            .structs = structs,
            .fields = fields,
        };
    }

    fn deinit(self: *const StructReaderSate) void {
        self.structs.deinit();
        self.fields.deinit();
    }
};

const ParserError = error{
    StopTokenNotFound,
    TooManyClosingBrackets,
    ClosingBracketNotFound,
    Other,
};

/// Writes tokens with spaces between them.
fn writeTokens(writer: anytype, toks: Toks, from: usize, to_excl: usize) !void {
    var first = true;
    for (from..to_excl) |i| {
        if (!first) {
            try writer.print(" ", .{});
        }
        first = false;

        const token = toks.tokens[i];
        if (tokenToOperatorStr(token) orelse tokenToKeywordStr(token)) |str| {
            try writer.print("{s}", .{str});
        } else if (toks.token_data[i]) |data| {
            try writer.print("{s}", .{data});
        } else {
            @panic("Unknown token");
        }
    }
}

fn writeCommentBefore(writer: anytype, toks: Toks, i: usize) !void {
    if (toks.comments_before_token[i]) |comment_range| {
        for (comment_range.from..comment_range.to_excl) |j| {
            _ = try writer.write(toks.comments[j]);
        }
    }
}

/// Comment after usually contains new line (unless it was terminated by eof).
fn writeCommentAfterOrNewLine(writer: anytype, toks: Toks, i: usize) !void {
    if (toks.comment_after_token[i]) |j| {
        _ = try writer.write(toks.comments[j]);
    } else {
        _ = try writer.write("\n");
    }
}

/// `prefix` is written at the beginning of the comment.
/// Tokens follow the prefix.
fn writeCommentWithTokens(
    writer: anytype,
    toks: Toks,
    from: usize,
    to_excl: usize,
    prefix: []const u8,
) !void {
    try writer.print("// {s}", .{prefix});
    try writeTokens(writer, toks, from, to_excl);
    _ = try writer.write("\n");
}

/// Works only for ASCII.
/// Used to translate function names.
fn writeInCamelCase(writer: anytype, snake_case: []const u8) !void {
    var found_letter = false;
    var capitalize_next = false;
    for (snake_case) |c| {
        if (found_letter) {
            if (c == '_') {
                capitalize_next = true;
            } else if (capitalize_next) {
                _ = try writer.write(&.{std.ascii.toUpper(c)});
                capitalize_next = false;
            } else {
                _ = try writer.write(&.{c});
            }
        } else {
            _ = try writer.write(&.{c});
            found_letter = std.ascii.isAlphabetic(c);
        }
    }
}

/// Works only for ASCII.
/// Used to translate union tags.
fn writeInSnakeCase(writer: anytype, pascal_case: []const u8) !void {
    var last_letter_capital = true;
    for (pascal_case) |c| {
        if (std.ascii.isUpper(c)) {
            if (!last_letter_capital)
                _ = try writer.write("_");
            _ = try writer.write(&.{std.ascii.toLower(c)});
            last_letter_capital = true;
        } else {
            _ = try writer.write(&.{c});
            last_letter_capital = false;
        }
    }
}

fn skipAttribute(toks: Toks, i: *usize) !bool {
    if (toks.match(i.*, "#![")) |m| {
        i.* += m.len;
        i.* += try toks.expressionLen(i.*, "]") + 1;
        return true;
    } else if (toks.match(i.*, "#[")) |m| {
        i.* += m.len;
        i.* += try toks.expressionLen(i.*, "]") + 1;
        return true;
    }
    return false;
}

fn translate(writer: anytype, toks: Toks, i: *usize, token: Token) !void {
    if (i.* < toks.tokens.len and toks.tokens[i.*] == token) {
        try writeTokens(writer, toks, i.*, i.* + 1);
        i.* += 1;
    } else return ParserError.Other;
}

fn translateOptional(writer: anytype, toks: Toks, i: *usize, token: Token) !void {
    if (i.* < toks.tokens.len and toks.tokens[i.*] == token) {
        try writeTokens(writer, toks, i.*, i.* + 1);
        i.* += 1;
    }
}

const TokenIndex = usize; // Index into `tokens`.
const SelfTypeRange = struct { from: TokenIndex, to_excl: TokenIndex };

// TODO: Translate `self_type` everywhere (eg. in generics) and not only when type is simple identifier.
// TODO: Consider generalizing `translateType`.
fn translateType(writer: anytype, toks: Toks, i: *usize, self_type: ?SelfTypeRange) !void {
    // All references are translated to pointer.
    if (toks.match(i.*, "& ' ident mut")) |m| {
        _ = try writer.write("*");
        i.* += m.len;
    } else if (toks.match(i.*, "& ' ident")) |m| {
        _ = try writer.write("*");
        i.* += m.len;
    } else if (toks.match(i.*, "& mut")) |m| {
        _ = try writer.write("*");
        i.* += m.len;
    } else if (toks.match(i.*, "&")) |m| {
        _ = try writer.write("*");
        i.* += m.len;
    }

    if (toks.match(i.*, "name ::")) |m| {
        try writer.print("{s}.", .{m.name});
        i.* += m.len;
        try translateType(writer, toks, i, self_type);
    } else if (toks.matchEql(i.*, "impl trait_name < type_name >", .{ .trait_name = "Into" })) |m| {
        try writer.print("{s}", .{m.type_name});
        i.* += m.len;
    } else if (toks.matchEql(i.*, "impl trait_name", .{ .trait_name = "ToString" })) |m| {
        try writer.print("[]const u8", .{});
        i.* += m.len;
    } else if (toks.matchEql(i.*, "arc < type_name >", .{ .arc = "Arc" })) |m| {
        try writer.print("{s}", .{m.type_name}); // TODO: Shouldn't we translate it to pointer?
        i.* += m.len;
    } else if (toks.matchEql(
        i.*,
        "arc < dyn any + send + sync >",
        .{ .arc = "Arc", .any = "Any", .send = "Send", .sync = "Sync" },
    )) |m| {
        _ = try writer.write("/* Ziggify: Pointer to anything clonable */");
        i.* += m.len;
    } else if (toks.matchEql(i.*, "option < type_name >", .{ .option = "Option" })) |m| {
        try writer.print("?{s}", .{m.type_name});
        i.* += m.len;
    } else if (toks.matchEql(i.*, "vec < vec2 < type_name > >", .{ .vec = "Vec", .vec2 = "Vec" })) |m| {
        // I doubt that nested `ArrayList` is good option in Zig.
        try writer.print("/* Ziggify: Vec<Vec<{s}>> */", .{m.type_name});
        i.* += m.len;
    } else if (toks.matchEql(i.*, "formatter < ' lifetime >", .{ .formatter = "Formatter" })) |m| {
        try writer.print("/* Ziggify: Formatter<'{s}> */", .{m.lifetime});
        i.* += m.len;
    } else if (toks.match(i.*, "impl fn_trait (")) |m| {
        if (!std.mem.eql(u8, m.fn_trait, "Fn") and
            !std.mem.eql(u8, m.fn_trait, "FnMut") and
            !std.mem.eql(u8, m.fn_trait, "FnOnce"))
        {
            @panic("Unsupported fn trait");
        }

        const from = i.*;
        i.* += m.len;
        i.* += try toks.typeLen(i.*, ")") + 1;

        // Skip return type.
        if (toks.match(i.*, "->")) |_| {
            i.* += 1;
            i.* += try toks.typeLen(i.*, "> ] ) } { ,");
        }

        _ = try writer.write("/* Ziggify: ");
        try writeTokens(writer, toks, from, i.*);
        _ = try writer.write(" */");
    } else if (toks.match(i.*, "name <")) |m| {
        // zig fmt: off
        const name =
            if (std.mem.eql(u8, "Vec", m.name)) "ArrayList"
            else m.name;
        // zig fmt: on

        try writer.print("{s}(", .{name});
        i.* += m.len;

        while (i.* < toks.tokens.len and toks.tokens[i.*] != .@">") {
            try translateType(writer, toks, i, self_type);
            try translateOptional(writer, toks, i, .@",");
        }

        if (toks.match(i.*, ">")) |m_closing| {
            _ = try writer.write(")");
            i.* += m_closing.len;
        }
    } else if (toks.startsWithAndGetData(i.*, &.{.d_ident})) |ld| {
        if (std.mem.eql(u8, ld.data, "Self")) {
            if (self_type) |range| {
                try writeTokens(writer, toks, range.from, range.to_excl);
            } else {
                try writer.print("{s}", .{ld.data});
            }
        } else {
            try writer.print("{s}", .{ld.data});
        }
        i.* += ld.len;
    } else if (toks.startsWith(i.*, &.{.@"["})) |len| {
        i.* += len;

        // This could be slice or array.
        switch (toks.tokens[i.* + try toks.typeLen(i.*, "; ]")]) {
            .@";" => {
                // In Rust array type is `[T; n]` but in Zig it's `[n]T`.
                // So we use buffer `buf` to delay writing `T` after `n`.
                var buf: [500]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                try translateType(fbs.writer(), toks, i, self_type);

                if (toks.match(i.*, "; size:num ]")) |m| {
                    try writer.print("[{s}]{s}", .{ m.size, fbs.getWritten() });
                    i.* += m.len;
                } else {
                    // Expected semicolon and length a closing bracket weren't found.
                    return ParserError.Other;
                }
            },
            .@"]" => {
                // Slice.
                _ = try writer.write("[]");
                try translateType(writer, toks, i, self_type);
                if (toks.match(i.*, "]")) |m|
                    i.* += m.len
                else
                    return ParserError.Other;
            },
            else => unreachable,
        }
    } else return ParserError.Other;
}

fn translateStruct(
    writer: anytype,
    toks: Toks,
    i: *usize,
) !bool {
    if (toks.match(i.*, "struct name <")) |m| {
        const generic_params_from = i.* + m.len - 1;
        const generic_params_to_excl = generic_params_from + try toks.typeLen(
            generic_params_from + 1,
            ">",
        ) + 2; // `+2` to include both `<` and `>`.
        try writeCommentWithTokens(
            writer,
            toks,
            generic_params_from,
            generic_params_to_excl,
            "Ziggify generic struct: ",
        );
        try writer.print("const {s} = struct ", .{m.name});
        i.* = generic_params_to_excl;
    } else if (toks.match(i.*, "struct name {")) |m| {
        try writer.print("const {s} = struct ", .{m.name});
        i.* += m.len - 1;
    } else return false;

    try translate(writer, toks, i, .@"{");
    _ = try writer.write("\n");

    while (i.* < toks.tokens.len) {
        // Process comment before field or before end of struct.
        try writeCommentBefore(writer, toks, i.*);

        // Ignore field visibility.
        const public = toks.tokens[i.*] == .kw_pub;
        if (public) {
            i.* += 1;
        }

        if (toks.startsWithAndGetData(i.*, &.{ .d_ident, .@":" })) |ld| {
            const field_name = ld.data;
            try writer.print("{s}: ", .{field_name});
            i.* += ld.len;

            try translateType(writer, toks, i, null);
            try writer.print(",", .{});

            try writeCommentAfterOrNewLine(writer, toks, i.*);
        } else {
            // Field doesn't start here.
            break;
        }

        if (toks.startsWith(i.*, &.{.@","})) |len| {
            i.* += len;
        }
    }

    try translate(writer, toks, i, .@"}");

    return true;
}

fn translateEnum(
    writer: anytype,
    toks: Toks,
    i: *usize,
) !bool {
    if (toks.match(i.*, "enum name {")) |m| {
        try writer.print("const {s} = union(enum) {{\n", .{m.name});
        i.* += m.len;
    } else return false;

    const enum_body_start = i.*;

    // In the first pass we go through Rust enum items and generate Zig union case for each item.
    // Enum tuple items with 2 or more fields are translated to union cases with `std.meta.Tuple`.
    // Enum struct items are translated to union cases with structs where these structs
    // will be generated by the second pass.
    while (i.* < toks.tokens.len) {
        // Process comment before enum item or before end of enum.
        try writeCommentBefore(writer, toks, i.*);

        if (toks.match(i.*, "name ,")) |m| {
            try writeInSnakeCase(writer, m.name);
            _ = try writer.write(",\n");
            i.* += m.len;
        } else if (toks.match(i.*, "name }")) |m| {
            try writeInSnakeCase(writer, m.name);
            _ = try writer.write(",\n");
            i.* += m.len - 1;
        } else if (toks.match(i.*, "name (")) |m| {
            i.* += m.len;
            const tuple_body_start = i.*;

            // We need to know whether tuple contains 0, 1 or more fields.
            const first_field_len = try toks.typeLen(i.*, ", )");
            if (first_field_len == 0) {
                // First tuple field is empty.
                // So we assume opening `(` is immediately followed by closing `)`.
                if (toks.tokens[i.*] != .@")") return ParserError.ClosingBracketNotFound;
                i.* += 1;

                // Ignore optional comma.
                if (toks.startsWith(i.*, &.{.@","})) |len| {
                    i.* += len;
                }
                try writeInSnakeCase(writer, m.name);
                _ = try writer.write(",\n");
            } else {
                // Tuple has at least one field.
                try writeInSnakeCase(writer, m.name);
                _ = try writer.write(": ");

                if (toks.tokens[i.* + first_field_len] == .@",") {
                    // Tuple may contain second field because there's comma after first field.
                    i.* += first_field_len + 1; // Skip first field and comma.
                    const second_field_len = try toks.typeLen(i.*, ", )");

                    if (second_field_len > 0) {
                        i.* = tuple_body_start;

                        // Enum tuple item has two or more fields so we store it's payload
                        // in `std.meta.Tuple`.
                        try writer.print("std.meta.Tuple(&.{{ ", .{});

                        // Translate types separated by comma.
                        while (i.* < toks.tokens.len and toks.tokens[i.*] != .@")") {
                            try translateType(writer, toks, i, null);
                            try translateOptional(writer, toks, i, .@",");
                        }

                        if (toks.startsWith(i.*, &.{.@")"})) |len| {
                            i.* += len;
                        } else return ParserError.ClosingBracketNotFound;

                        // Ignore optional comma after enum tuple item.
                        if (toks.startsWith(i.*, &.{.@","})) |len| {
                            i.* += len;
                        }
                        try writer.print(" }}),\n", .{});

                        continue; // Avoid code which translates tuples with one field.
                    }
                }

                // Tuple has exactly one field.

                try translateType(writer, toks, i, null);
                // Ignore optional comma after type inside the tuple.
                if (toks.match(i.*, ",")) |m_comma| {
                    i.* += m_comma.len;
                }

                if (toks.startsWith(i.*, &.{.@")"})) |len| {
                    i.* += len;
                } else return ParserError.ClosingBracketNotFound;

                // Ignore optional comma after enum tuple item.
                if (toks.startsWith(i.*, &.{.@","})) |len| {
                    i.* += len;
                }
                try writer.print(",\n", .{});
            }
        } else if (toks.match(i.*, "name {")) |m| {
            i.* += m.len;
            i.* += try toks.expressionLen(i.*, "}") + 1;
            // Ignore optional comma after enum struct item.
            if (toks.startsWith(i.*, &.{.@","})) |len| {
                i.* += len;
            }
            try writeInSnakeCase(writer, m.name);
            try writer.print(": {s},\n", .{m.name});
        } else {
            break;
        }
    }

    // We don't want to translate closing `}` yet because there is still the second pass
    // which may generate nested structs.
    if (toks.match(i.*, "}") == null)
        return ParserError.ClosingBracketNotFound;

    // Second pass generates Zig struct for each Rust enum struct item.
    i.* = enum_body_start;
    while (i.* < toks.tokens.len) {
        if (toks.match(i.*, "name ,")) |m| {
            i.* += m.len;
        } else if (toks.match(i.*, "name }")) |m| {
            i.* += m.len - 1; // Don't skip closing `}`.
            break;
        } else if (toks.match(i.*, "name (")) |m| {
            i.* += m.len;
            i.* += try toks.expressionLen(i.*, ")") + 1;
            if (toks.match(i.*, ",")) |m_comma|
                i.* += m_comma.len;
        } else if (toks.match(i.*, "name {")) |m| {
            // This code is similar but not same as in `translateStruct`.
            // It would be nice to share it.

            try writer.print("const {s} = struct {{\n", .{m.name});
            i.* += m.len;

            while (i.* < toks.tokens.len) {
                if (toks.startsWithAndGetData(i.*, &.{ .d_ident, .@":" })) |ld| {
                    const field_name = ld.data;
                    try writer.print("{s}: ", .{field_name});
                    i.* += ld.len;

                    try translateType(writer, toks, i, null);
                    try writer.print(",", .{});

                    // Ignore optional comma after struct field.
                    if (toks.startsWith(i.*, &.{.@","})) |len| {
                        i.* += len;
                    }
                } else {
                    // Struct field doesn't start here.
                    break;
                }
            }

            _ = try writer.write("\n");
            try translate(writer, toks, i, .@"}");
            _ = try writer.write(";\n");

            // Ignore optional comma after struct.
            if (toks.startsWith(i.*, &.{.@","})) |len| {
                i.* += len;
            }
        } else {
            // Probably end of enum.
            break;
        }
    }

    _ = try writer.write("\n");
    try translate(writer, toks, i, .@"}");
    _ = try writer.write(";\n");

    return true;
}

/// Translates body of a function, if, else, for, while or loop.
/// Also translates control expression of if, for, while and match.
///
/// `translateBody` doesn't parse closing `}` or `]` unless it parsed corresponding opening bracket.
/// Currently this is not true with parens.
fn translateBody(writer: anytype, toks: Toks, i: *usize, self_type: ?SelfTypeRange) !void {
    while (i.* < toks.tokens.len) {
        // Process comment before construct or before end of module.
        try writeCommentBefore(writer, toks, i.*);

        if (try skipAttribute(toks, i)) {
            //
        } else if (toks.match(i.*, "&mut |")) |m| {
            _ = try writer.write("/* Ziggify: ");
            try writeTokens(writer, toks, i.*, i.* + m.len);
            i.* += m.len;

            const len = try toks.expressionLen(i.*, "|") + 1;
            try writeTokens(writer, toks, i.*, i.* + len);
            _ = try writer.write(" */ ");
            i.* += len;

            try translate(writer, toks, i, .@"{");
            _ = try writer.write("\n");

            try translateBody(writer, toks, i, self_type);

            _ = try writer.write("\n");
            try translate(writer, toks, i, .@"}");
            _ = try writer.write("\n");
        } else if (toks.match(i.*, "&mut")) |m| {
            _ = try writer.write("&");
            i.* += m.len;
        } else if (toks.match(i.*, "&&")) |m| {
            _ = try writer.write(" and ");
            i.* += m.len;
        } else if (toks.match(i.*, "||")) |m| {
            _ = try writer.write(" or ");
            i.* += m.len;
        } else if (toks.match(i.*, ";")) |m| {
            // This doesn't match `;` inside array construction -
            // that is translated by `[` part.
            _ = try writer.write(";");
            // We must increment `i` after writing comment.
            try writeCommentAfterOrNewLine(writer, toks, i.*);
            i.* += m.len;
        } else if (toks.match(i.*, "::")) |m| {
            // Double colon doesn't exist in Zig.
            _ = try writer.write(" . ");
            i.* += m.len;
        } else if (toks.startsWithAny(
            i.*,
            &.{
                &.{.@"..="}, &.{.@".."}, &.{.@"=="}, &.{.@"<="}, &.{.@"<"},
                &.{.@">="},  &.{.@">"},  &.{.@"."},  &.{.@"|"},  &.{.@"!"},
                &.{.@"&"},   &.{.@","},  &.{.@"*"},  &.{.@"/"},  &.{.@"+"},
                &.{.@"-"},   &.{.@":"},  &.{.@"="},  &.{.@"("},  &.{.@")"},
            },
        )) |len| {
            // Operators which are translated to themselves.
            //
            // Note that some of these translations are wrong.
            // Eg. `|` as a bitwise or is correctly translated to itself.
            // But `|` from lambda (eg. from `|t: f32| t <= 1.0 && t >= 0.0`)
            // can't be simply translated to Zig because Zig doesn't have lambdas
            // and translating it to itself is wrong.
            _ = try writer.write(" ");
            try writeTokens(writer, toks, i.*, i.* + len);
            _ = try writer.write(" ");
            i.* += len;
        } else if (toks.match(i.*, "[")) |_| {
            try translate(writer, toks, i, .@"[");

            // If there's `;` before closing brace `]` then
            // we need to translate array construction `[expression with value; array size]`.
            // Otherwise we're indexing.
            const len_before = try toks.expressionLen(i.*, "; ]");
            if (toks.tokens[i.* + len_before] == .@";") {
                // Array construction.
                try translateBody(writer, toks.restrict(i.* + len_before), i, self_type);
                // We don't want to translate `;` by `translateBody` because it puts newline after semicolon.
                try translate(writer, toks, i, .@";");
                try translateBody(writer, toks, i, self_type);
                try translate(writer, toks, i, .@"]");
            } else {
                // Indexing.
                try translateBody(writer, toks, i, self_type);
                try translate(writer, toks, i, .@"]");
            }
        } else if (toks.match(i.*, "fn name")) |_| {
            // Nested function are not very common.
            // For now we don't translate them.
            const function_body_start = i.* + try toks.expressionLen(i.*, "{") + 1;
            const function_body_end = function_body_start + try toks.expressionLen(function_body_start, "}") + 1;
            try writeCommentWithTokens(writer, toks, i.*, function_body_end, "Ziffigy: ");
            i.* = function_body_end;
        } else if (toks.match(i.*, "name {")) |m_struct| {
            // Struct construction `identifier {` may clash with the end of control
            // expression in if, for, while or match (eg. `if a + b {`).
            //
            // Currently we assume that control expression doesn't contain opening `{` -
            // ie. we assume that opening `{` is beginning of the body of if, for, while or match expression.
            // This may be wrong. We may need more involved analysis
            // (eg. if identifier in `identifier {` starts with uppercase letter
            // then assume it's struct construction).
            if (std.mem.eql(u8, m_struct.name, "Self")) {
                if (self_type) |range| {
                    try writeTokens(writer, toks, range.from, range.to_excl);
                } else {
                    try writer.print("{s}", .{m_struct.name});
                }
                _ = try writer.write(" {");
            } else try writer.print("{s} {{", .{m_struct.name});
            i.* += m_struct.len;

            // Translate assignment to fields.
            while (i.* < toks.tokens.len) {
                if (toks.match(i.*, "name ,")) |m_field| {
                    try writer.print(".{s} = {s},", .{ m_field.name, m_field.name });
                    i.* += m_field.len;
                } else if (toks.match(i.*, "name )")) |m_field| {
                    try writer.print(".{s} = {s}", .{ m_field.name, m_field.name });
                    i.* += m_field.len - 1; // Don't skip closing paren.
                } else if (toks.match(i.*, "name :")) |m_field| {
                    try writer.print(".{s} = ", .{m_field.name});
                    i.* += m_field.len;

                    const len_before = try toks.expressionLen(i.*, ", }");
                    try translateBody(writer, toks.restrict(i.* + len_before), i, self_type);

                    // Translate comma (if any).
                    try translateOptional(writer, toks, i, .@",");
                } else break;
            }

            try translate(writer, toks, i, .@"}");
        } else if (toks.match(i.*, "fn_name (")) |m| {
            // Function call - we have to convert function name to camel case.

            try writeInCamelCase(writer, m.fn_name);
            i.* += m.len - 1; // We're not translating `(`.
        } else if (toks.match(i.*, "ident")) |m| {
            // TODO: Are spaces around necessary or is it ok without them?
            _ = try writer.write(m.ident);
            i.* += m.len;
        } else if (toks.match(i.*, "number:num")) |m| {
            // TODO: Are spaces around necessary or is it ok without them?
            _ = try writer.write(m.number);
            i.* += m.len;
        } else if (toks.match(i.*, "string:str")) |m| {
            // TODO: Are spaces around necessary or is it ok without them?
            _ = try writer.write(m.string);
            i.* += m.len;
        } else if (toks.match(i.*, "let mut ident =")) |m| {
            try writer.print("var {s} = ", .{m.ident});
            i.* += m.len;
        } else if (toks.match(i.*, "let ident =")) |m| {
            try writer.print("const {s} = ", .{m.ident});
            i.* += m.len;
        } else if (toks.match(i.*, "let")) |m| {
            _ = try writer.write("const ");
            i.* += m.len;

            // Complex patterns are not translated.
            const len_before = try toks.expressionLen(i.*, "=");
            _ = try writer.write("/* Ziggify: ");
            try writeTokens(writer, toks, i.*, i.* + len_before);
            _ = try writer.write(" */ ");
            i.* += len_before;

            try translate(writer, toks, i, .@"=");
        } else if (toks.match(i.*, "while")) |m| {
            _ = try writer.write("while (");
            i.* += m.len;

            // Translate expression after `while` to the first `{`.
            // Note it may happen that `{` belongs to struct construction and not to `while` body.
            const len_before_brace = try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(i.* + len_before_brace), i, self_type);
            try writer.print(") ", .{});
        } else if (toks.match(i.*, "for elem in")) |m| {
            _ = try writer.write("for (");
            i.* += m.len;

            // Translate expression after `in` to the first `{`.
            // Note it may happen that `{` belongs to struct construction and not to `for` body.
            const len_before_brace = try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(i.* + len_before_brace), i, self_type);
            try writer.print(") |{s}|", .{m.elem});
        } else if (toks.match(i.*, "for (index, elem) in")) |m| {
            // Note it may happen that `{` belongs to struct construction and not to `for` body.
            const for_start_len = try toks.expressionLen(i.*, "{");
            const enumerate_len = 8;

            // If expression after `in` ends with `.iter().enumerate()`.
            if (toks.matchEql(
                i.* + for_start_len - enumerate_len,
                ".iter().enumerate()",
                .{ .iter = "iter", .enumerate = "enumerate" },
            )) |_| {
                _ = try writer.write("for (");

                // Translate expression after `in` except `.iter().enumerate()`.
                // We create `temp_toks` which doesn't contain `.iter().enumerate()`.
                const token_count = i.* + for_start_len - enumerate_len;
                const temp_toks = toks.restrict(token_count);
                var temp_i = i.* + m.len; // We don't want to update `i`.
                try translateBody(writer, temp_toks, &temp_i, self_type);
                if (temp_i != token_count)
                    @panic("Expression after in not processed whole");
                try writer.print(", 0..) |{s}, {s}|", .{ m.elem, m.index });
                i.* += for_start_len;
            } else @panic("Control expression of for doesn't end with .iter().enumerate()");
        } else if (toks.match(i.*, "if let")) |m| {
            _ = try writer.write("if (/* Ziggify: ");
            i.* += m.len;

            const pattern_start = i.*;
            const pattern_len = try toks.expressionLen(i.*, "=");
            _ = try writeTokens(writer, toks, pattern_start, pattern_start + pattern_len);
            _ = try writer.write(" */ ");
            i.* += pattern_len + 1;

            const right_side_len = try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(i.* + right_side_len), i, self_type);
            _ = try writer.write(") ");
        } else if (toks.startsWithAny(i.*, &.{&.{.kw_if}})) |len| {
            try writeTokens(writer, toks, i.*, i.* + len);
            i.* += len;

            _ = try writer.write("(");
            // Translate control expression to the first `{`.
            // Note it may happen that `{` belongs to struct construction and not to `if` body.
            const len_before_brace = try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(i.* + len_before_brace), i, self_type);
            _ = try writer.write(")");
        } else if (toks.match(i.*, "else if")) |_| {
            // Translate just `else` so `if` can be translated by `if let` or normal `if`.
            _ = try writer.write("else ");
            i.* += 1;
        } else if (toks.match(i.*, "else {")) |_| {
            // Translate just `else`.
            try translate(writer, toks, i, .kw_else);
        } else if (toks.match(i.*, "return")) |_| {
            // Translate just `return`.
            try translate(writer, toks, i, .kw_return);
            _ = try writer.write(" ");
        } else if (toks.startsWith(i.*, &.{.kw_match})) |len| {
            _ = try writer.write("switch (");
            i.* += len;

            // Translate match control expression to the first `{`.
            // Note it may happen that `{` belongs to struct construction and not to `match` body.
            const len_before_brace = try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(i.* + len_before_brace), i, self_type);
            _ = try writer.write(")");

            try translate(writer, toks, i, .@"{");
            _ = try writer.write("\n");

            // Translate each case.
            while (i.* < toks.tokens.len) {
                // Translate pattern.
                const pattern_len = try toks.expressionLen(i.*, "=> }");
                if (pattern_len == 0) break; // No more patterns.
                _ = try writer.write("/* Ziggify: ");
                try writeTokens(writer, toks, i.*, i.* + pattern_len);
                _ = try writer.write(" */");
                i.* += pattern_len;
                try translate(writer, toks, i, .@"=>");

                if (toks.startsWith(i.*, &.{.@"{"})) |_| {
                    // Code for current case is enclosed in braces.
                    try translate(writer, toks, i, .@"{");
                    _ = try writer.write("\n");

                    try translateBody(writer, toks, i, self_type);

                    _ = try writer.write("\n");
                    try translate(writer, toks, i, .@"}");
                } else {
                    // Code for current case is terminated by `,` or `}` ending the body of `match`.
                    const case_len = try toks.expressionLen(i.*, ", }");
                    try translateBody(writer, toks.restrict(i.* + case_len), i, self_type);

                    try translateOptional(writer, toks, i, .@",");
                }
                _ = try writer.write("\n");
            }

            _ = try writer.write("\n");
            try translate(writer, toks, i, .@"}");
            _ = try writer.write("\n");
        } else if (toks.match(i.*, "{")) |_| {
            try translate(writer, toks, i, .@"{");
            _ = try writer.write("\n");

            try translateBody(writer, toks, i, self_type);

            _ = try writer.write("\n");
            try translate(writer, toks, i, .@"}");
            _ = try writer.write("\n");
        } else {
            // Nothing was parsed we have to stop.
            // Probably end of body. Or some unknown construct.
            break;
        }
    }
}

fn translateFn(writer: anytype, toks: Toks, i: *usize, public: bool, self_type: ?SelfTypeRange) !bool {
    if (toks.startsWithAnyAndGetData(i.*, &.{
        &.{ .kw_fn, .d_ident },
        // Functions which can be evaluated at compile time.
        // These in Zig don't need `const` or any other special flag.
        &.{ .kw_const, .kw_fn, .d_ident },
    })) |ld| {
        const fn_name = ld.data;
        if (public)
            try writer.print("pub fn ", .{})
        else
            try writer.print("fn ", .{});

        try writeInCamelCase(writer, fn_name);
        i.* += ld.len;

        const len_before_paren = try toks.typeLen(i.*, "(");
        if (len_before_paren > 0) {
            _ = try writer.write(" /* ");
            try writeTokens(writer, toks, i.*, i.* + len_before_paren);
            _ = try writer.write(" */ ");
            i.* += len_before_paren;
        }

        try translate(writer, toks, i, .@"(");

        // Translate first parameter where type can be omitted.
        if (self_type) |range| {
            if (toks.startsWithAnyAndGetData(
                i.*,
                &.{
                    // There may be comma or closing paren after the first param.
                    &.{ .d_ident, .@"," },
                    &.{ .d_ident, .@")" },
                    &.{ .@"&", .d_ident, .@"," },
                    &.{ .@"&", .d_ident, .@")" },
                },
            )) |ld_param| {
                const param_name = ld_param.data;
                try writer.print("{s}: ", .{param_name});
                try writeTokens(writer, toks, range.from, range.to_excl);
                i.* += ld_param.len;

                if (toks.tokens[i.* - 1] == .@",") {
                    _ = try writer.write(",");
                } else {
                    i.* -= 1; // Don't skip `)` token.
                }
            } else if (toks.startsWithAnyAndGetData(
                i.*,
                &.{
                    // There may be comma or closing paren after the first param.
                    &.{ .kw_mut, .d_ident, .@"," },
                    &.{ .kw_mut, .d_ident, .@")" },
                    &.{ .@"&", .kw_mut, .d_ident, .@"," },
                    &.{ .@"&", .kw_mut, .d_ident, .@")" },
                },
            )) |ld_param| {
                const param_name = ld_param.data;
                try writer.print("{s}: *", .{param_name});
                try writeTokens(writer, toks, range.from, range.to_excl);
                i.* += ld_param.len;

                if (toks.tokens[i.* - 1] == .@",") {
                    _ = try writer.write(",");
                } else {
                    i.* -= 1; // Don't skip `)` token.
                }
            }
        }

        while (i.* < toks.tokens.len) {
            if (toks.startsWithAnyAndGetData(i.*, &.{
                &.{ .d_ident, .@":", .@"&", .@"'", .d_ident, .kw_mut },
                &.{ .d_ident, .@":", .@"&", .kw_mut },
            })) |ld_param| {
                const param_name = ld_param.data;
                try writer.print("{s}: *", .{param_name});
                i.* += ld_param.len;

                try translateType(writer, toks, i, self_type);
            } else if (toks.startsWithAnyAndGetData(
                i.*,
                &.{
                    &.{ .d_ident, .@":", .@"&", .@"'", .d_ident },
                    &.{ .d_ident, .@":", .@"&" },
                    &.{ .d_ident, .@":" },
                },
            )) |ld_param| {
                // Immutable param.
                const param_name = ld_param.data;
                try writer.print("{s}: ", .{param_name});
                i.* += ld_param.len;

                try translateType(writer, toks, i, self_type);
            } else break;

            if (toks.startsWith(i.*, &.{.@","})) |len| {
                _ = try writer.write(",");
                i.* += len;
            }

            // TODO: Read comment associated with a parameter (it's before or after? or both?).
        }

        if (toks.startsWith(i.*, &.{.@")"})) |len| {
            _ = try writer.write(")");
            i.* += len;
        } else {
            return ParserError.ClosingBracketNotFound;
        }

        // Translate optional return type.
        if (toks.startsWith(i.*, &.{.@"->"})) |len| {
            i.* += len;
            // TODO: Instead of returning self return actual type.
            try translateType(writer, toks, i, self_type);
        } else {
            _ = try writer.write("void");
        }

        // Translate optional where clause - just wrap it in comment.
        if (toks.startsWith(i.*, &.{.kw_where})) |_| {
            const where_len = try toks.expressionLen(i.*, "{");
            _ = try writer.write(" /* ");
            try writeTokens(writer, toks, i.*, i.* + where_len);
            _ = try writer.write(" */ ");
            i.* += where_len;
        }

        try translate(writer, toks, i, .@"{");
        _ = try writer.write("\n");

        try translateBody(writer, toks, i, self_type);

        _ = try writer.write("\n");
        try translate(writer, toks, i, .@"}");
        _ = try writer.write("\n");

        return true;
    }
    return false;
}

fn translateImpl(writer: anytype, toks: Toks, i: *usize) !bool {
    const impl_from = i.*;

    var self_type: SelfTypeRange = undefined;
    if (toks.match(i.*, "impl")) |m| {
        i.* += m.len;

        // Skip tokens so we get before type.
        const len = try toks.typeLen(i.*, "for {");
        switch (toks.tokens[i.* + len]) {
            .kw_for => {
                // It's a trait implementation.

                i.* += len + 1; // Skip tokens up to and including `for`.
            },
            .@"{" => {
                // It's inherent implementation.

                // Skip generic params if any.
                if (toks.match(i.*, "<")) |m_generic_params| {
                    i.* += m_generic_params.len;
                    i.* += try toks.typeLen(i.*, ">") + 1;
                }
            },
            else => unreachable,
        }

        // Now we're before type. The type continues till `where` or `{`.
        self_type = .{
            .from = i.*,
            .to_excl = i.* + try toks.typeLen(i.*, "where {"),
        };

        i.* = self_type.to_excl;

        // Skip `where` if there's one.
        // We should be right before opening brace which encloses `impl` body.
        i.* += try toks.typeLen(i.*, "{");
    } else return false;

    const impl_to_excl = i.*;
    i.* += 1; // Skip opening `{`.

    try writeCommentWithTokens(writer, toks, impl_from, impl_to_excl, "BEGIN: ");

    try translateRustToZig(writer, toks, i, self_type);

    if (toks.match(i.*, "}")) |_| {
        i.* += 1; // Skip closing `}`.
        _ = try writer.write("\n");
    }

    try writeCommentWithTokens(writer, toks, impl_from, impl_to_excl, "END: ");

    return true;
}

fn translateRustToZig(
    writer: anytype,
    toks: Toks,
    i: *usize,
    self_type: ?SelfTypeRange,
) (@TypeOf(writer).Error || ParserError || Allocator.Error)!void {
    while (i.* < toks.tokens.len) {
        // Process comment before construct or before end of module.
        try writeCommentBefore(writer, toks, i.*);

        const public = toks.tokens[i.*] == .kw_pub;
        if (public) {
            i.* += 1;
        }

        if (try skipAttribute(toks, i)) {
            //
        } else if (toks.startsWith(i.*, &.{.kw_use})) |len| {
            i.* += len;
            i.* += try toks.expressionLen(i.*, ";") + 1;
        } else if (toks.match(i.*, "const name :")) |m| {
            try writer.print("const {s} : ", .{m.name});
            i.* += m.len;
            try translateType(writer, toks, i, self_type);

            try translate(writer, toks, i, .@"=");

            const right_side_len = try toks.expressionLen(i.*, ";");
            try translateBody(writer, toks.restrict(i.* + right_side_len), i, self_type);

            try translate(writer, toks, i, .@";");
            _ = try writer.write("\n");
        } else if (try translateStruct(writer, toks, i)) {
            //
        } else if (try translateEnum(writer, toks, i)) {
            //
        } else if (try translateImpl(writer, toks, i)) {
            //
        } else if (try translateFn(writer, toks, i, public, self_type)) {
            //
        } else if (toks.match(i.*, "mod name {")) |m| {
            // TODO: Translate Rust modules into structs?
            const mod_from = i.*;
            const mod_to_excl = i.* + m.len - 1;
            try writeCommentWithTokens(writer, toks, mod_from, mod_to_excl, "BEGIN: ");
            i.* += m.len;

            try translateRustToZig(writer, toks, i, self_type);

            _ = try writer.write("\n");
            try translate(writer, toks, i, .@"}");
            _ = try writer.write("\n");
            try writeCommentWithTokens(writer, toks, mod_from, mod_to_excl, "END: ");
        } else {
            break;
        }
    }
}

fn compareFiles(allocator: Allocator, sub_path: []const u8, sub_path2: []const u8) !bool {
    const f = try std.fs.cwd().openFile(sub_path, .{});
    defer f.close();

    const data = try f.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(data);

    const f2 = try std.fs.cwd().openFile(sub_path2, .{});
    defer f2.close();

    const data2 = try f2.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(data2);

    return std.mem.eql(u8, data, data2);
}

test "expected tokenization" {
    const paths_input = [_][]const u8{
        "test-data/epaint-bezier.rs",
        "test-data/epaint-shape.rs",
    };
    const paths_tokenized_expected = [_][]const u8{
        "test-data/epaint-bezier.tokenized",
        "test-data/epaint-shape.tokenized",
    };
    const paths_tokenized_actual = [_][]const u8{
        "tmp/epaint-bezier.tokenized",
        "tmp/epaint-shape.tokenized",
    };
    const paths_translated_expected = [_][]const u8{
        "test-data/epaint-bezier.translated",
        "test-data/epaint-shape.translated",
    };
    const paths_translated_actual = [_][]const u8{
        "tmp/epaint-bezier.translated",
        "tmp/epaint-shape.translated",
    };

    try std.fs.cwd().makePath("tmp");
    const allocator = std.testing.allocator;

    for (
        paths_input,
        paths_tokenized_expected,
        paths_tokenized_actual,
        paths_translated_expected,
        paths_translated_actual,
    ) |
        input,
        tokenized_expected,
        tokenized_actual,
        translated_expected,
        translated_actual,
    | {
        const input_file = try std.fs.cwd().openFile(input, .{});
        defer input_file.close();

        const data = try input_file.readToEndAlloc(allocator, 2 * 1024 * 1024);
        defer allocator.free(data);

        var toks = try tokenize(data, allocator);
        defer toks.deinit(allocator);

        // Write tokens with associated comments to file.
        {
            const output_file = try std.fs.cwd().createFile(tokenized_actual, .{});
            defer output_file.close();
            const writer = output_file.writer();
            for (toks.tokens, toks.token_data, 0..) |t, token_data, i| {
                if (toks.comments_before_token[i]) |comments| {
                    for (comments.from..comments.to_excl) |j| {
                        try writer.print("    BEFORE: {s}", .{toks.comments[j]});
                    }
                }

                if (token_data) |d| {
                    try writer.print("Token {}: {s}\n", .{ t, d });
                } else {
                    try writer.print("Token {}\n", .{t});
                }

                if (toks.comment_after_token[i]) |j| {
                    try writer.print("    AFTER: {s}", .{toks.comments[j]});
                }
            }
        }
        std.debug.print("Checking tokenization {s}\n", .{tokenized_actual});
        try std.testing.expect(try compareFiles(allocator, tokenized_expected, tokenized_actual));

        // Write tokens with associated comments to file.
        {
            const output_file = try std.fs.cwd().createFile(translated_actual, .{});
            defer output_file.close();
            const writer = output_file.writer();
            var i: usize = 0;
            translateRustToZig(
                writer,
                toks,
                &i,
                null,
            ) catch |e| {
                std.debug.print("Error: {}\n", .{e});
                std.debug.print("Unknown construct while translating {any}\n", .{
                    if (toks.tokens[i..].len < 20) toks.tokens[i..] else toks.tokens[i..][0..20],
                });
            };
        }
        std.debug.print("Checking translation {s}\n", .{translated_actual});
        try std.testing.expect(try compareFiles(allocator, translated_expected, translated_actual));
    }
}

pub fn main() !void {
    const file = try std.fs.cwd().openFile("sample.rs", .{});
    defer file.close();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const data = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(data);

    var toks = try tokenize(data, allocator);
    defer toks.deinit(allocator);

    // Print tokens with associated comments.
    for (toks.tokens, toks.token_data, 0..) |t, token_data, i| {
        if (toks.comments_before_token[i]) |comments| {
            for (comments.from..comments.to_excl) |j| {
                std.debug.print("    BEFORE: {s}", .{toks.comments[j]});
            }
        }

        if (token_data) |d| {
            std.debug.print("Token {}: {s}\n", .{ t, d });
        } else {
            std.debug.print("Token {}\n", .{t});
        }

        if (toks.comment_after_token[i]) |j| {
            std.debug.print("    AFTER: {s}", .{toks.comments[j]});
        }
    }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    var i: usize = 0;
    translateRustToZig(
        bw.writer(),
        toks,
        &i,
        null,
    ) catch |e| {
        std.debug.print("Error: {}\n", .{e});
        std.debug.print("Unknown construct while translating {any}\n", .{
            if (toks.tokens[i..].len < 20) toks.tokens[i..] else toks.tokens[i..][0..20],
        });
    };
    try bw.flush();
}
