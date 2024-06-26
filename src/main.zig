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
    kw_type,
    kw_const,
    kw_static,
    kw_fn,
    kw_where,
    kw_trait,
    kw_impl,
    kw_dyn,
    kw_while,
    kw_for,
    kw_in,
    kw_if,
    kw_else,
    kw_match,
    kw_let,
    kw_mut,
    kw_return,
    kw_as,

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
    @"?",
    @"!", // For macros.
    @"&",
    @",",
    @";",
    @"*",
    @"/",
    @"%",
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
        if (std.mem.indexOfScalar(u8, data[0..i], '\n')) |_| {
            const context = if (data.len > 200)
                data[0..200]
            else
                data;
            std.debug.print("Multiline string: {s}", .{context});
            return TokenizerError.MultilineStringsNotSupported;
        }
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

const CommentIndex = usize; // Index into `comments`.
const CommentRange = struct { from: CommentIndex, to_excl: CommentIndex };

const Match = struct {
    const Pattern = struct {
        tokens: []const Token,
        // Names of struct fields into which token data will be captured.
        capture_field_names: []const ?[]const u8,
        // Number of non-null `capture_field_names`.
        capture_count: usize,

        fn compareStrings(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs).compare(std.math.CompareOperator.lt);
        }

        fn getCaptureFieldNamesOrdered(comptime pattern: Pattern) [pattern.capture_count][]const u8 {
            var result: [pattern.capture_count][]const u8 = undefined;

            // First step is to get non-null field names.
            var i: usize = 0;
            for (pattern.capture_field_names) |optional_field_name| {
                if (optional_field_name) |field_name| {
                    result[i] = field_name;
                    i += 1;
                }
            }
            if (i != pattern.capture_count)
                @compileError("Wrong capture_count");

            // Second step is to sort field names.
            std.sort.pdq([]const u8, &result, {}, compareStrings);

            return result;
        }
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

    fn matchAny(self: Toks, i: usize, comptime patterns: []const []const u8) ?Match.Result(patterns[0]) {
        comptime if (patterns.len == 0)
            @compileError("At least one pattern must be given");
        comptime var pats: [patterns.len]Match.Pattern = undefined;
        inline for (patterns, 0..) |pattern, j| {
            pats[j] = comptime Match.parsePattern(pattern);
        }

        // Check that all patterns capture same fields.
        // Order of captured fields is not important.
        const capture_field_names = comptime pats[0].getCaptureFieldNamesOrdered();
        inline for (1..pats.len) |j| {
            const capture_field_names2 = comptime pats[j].getCaptureFieldNamesOrdered();
            comptime if (capture_field_names.len != capture_field_names2.len)
                @compileError("All patterns must capture same fields");
            inline for (capture_field_names, capture_field_names2) |name, name2| {
                comptime if (!std.mem.eql(u8, name, name2))
                    @compileError("Field names differ: " ++ name ++ " is not equal to " ++ name2);
            }
        }

        inline for (pats) |pat| {
            if (std.mem.startsWith(Token, self.tokens[i..], pat.tokens)) {
                var result: Match.Result(patterns[0]) = undefined;
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
        }
        return null;
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
            const context = if (data.len > 200)
                data[0..200]
            else
                data;
            std.debug.print("Unrecognized token: {s}", .{context});
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

fn translateSimpleType(
    writer: anytype,
    toks: Toks,
    i: *usize,
    self_type: ?SelfTypeRange,
) !bool {
    const type_from = i.*;

    // All kinds of references are translated to pointer.
    var is_pointer = false;
    if (toks.matchAny(i.*, &.{
        "& ' _lifetime mut",
        "& ' static mut",
        "& ' _lifetime",
        "& ' static",
        "& mut",
        "&",
    })) |m| {
        is_pointer = true;
        i.* += m.len;
    }

    const non_ref_from = i.*;
    if (toks.match(i.*, "ident ::")) |_| {
        // Handle all types starting with path.
        // Only non-generic types with path can be translated.
        // For example `foo::bar::Baz` is ok but `foo:bar::Baz<i32>` is not ok.

        // Find end of path and check that the type is non-generic.
        while (toks.match(i.*, "ident ::")) |m| {
            i.* += m.len;
        }
        if (toks.match(i.*, "ident <")) |_| {
            // Generic types are not supported.
            i.* = type_from;
            return false;
        }
        if (toks.match(i.*, "ident") == null) {
            // There's no type at the end of path.
            i.* = type_from;
            return false;
        }

        // Now we checked that we can translate this case. so let's actually translate it.
        i.* = non_ref_from;
        if (is_pointer)
            _ = try writer.write("*");
        // Translate path.
        while (toks.match(i.*, "ident ::")) |m| {
            try writer.print("{s}.", .{m.ident});
            i.* += m.len;
        }
        // Translate non-generic type.
        const m = toks.match(i.*, "ident").?;
        _ = try writer.print("{s}", .{m.ident});
        i.* += m.len;

        return true;
    } else if (toks.match(i.*, "impl name")) |m_trait| {
        // Handle simple impls (impls starting with `impl for<` are not matched).
        // Only `impl ToString` and `impl Into<T>` are translated.
        i.* += m_trait.len;

        if (std.mem.eql(u8, m_trait.name, "ToString")) {
            // Translate `impl ToString` to `[]const u8`.
            // Ensure that `ToString` is not followed by `<` or `+`.
            if (toks.matchAny(i.*, &.{ "<", "+" })) |_| {
                i.* = type_from;
                return false;
            }

            if (is_pointer)
                _ = try writer.write("*");
            _ = try writer.write("[]const u8");

            return true;
        } else if (std.mem.eql(u8, m_trait.name, "Into")) {
            // Translate `impl Into<T>` to translation of `T`.

            if (toks.match(i.*, "<")) |m_opening| {
                i.* += m_opening.len;
            } else {
                i.* = type_from;
                return false;
            }
            const inner_type_from = i.*;
            // Check that there's no comma between `<` and `>`.
            const inner_type_len = try toks.typeLen(i.*, ", >");
            if (toks.match(i.* + inner_type_len, ",")) |_| {
                // Generics with multiple parameters are not supported.
                i.* = type_from;
                return false;
            }

            i.* += inner_type_len + 1; // Skip closing `>`.

            // Ensure that `impl Into<T>` is not followed by `+`.
            if (toks.match(i.*, "+")) |_| {
                i.* = type_from;
                return false;
            }

            // Now we checked that we can translate this case. so let's actually translate it.
            i.* = inner_type_from;
            if (is_pointer)
                _ = try writer.write("*");
            try translateType(writer, toks, i, self_type);

            // Ensure that whole inner type has been translated.
            if (i.* != inner_type_from + inner_type_len)
                return ParserError.Other;

            // Skip closing `>`.
            i.* += 1;

            return true;
        } else {
            // Unsupported trait.

            i.* = type_from;
            return false;
        }
    } else if (toks.match(i.*, "ident <")) |m_generic| {
        // Handle generic types.
        // Only `Option<T>` and `Vec<T>` are translated.

        i.* += m_generic.len;

        const inner_type_from = i.*;
        // Check that there's no comma between `<` and `>`.
        const inner_type_len = try toks.typeLen(i.*, ", >");
        if (toks.match(i.* + inner_type_len, ",")) |_| {
            // Generics with multiple parameters are not supported.
            i.* = type_from;
            return false;
        }

        var prefix: []const u8 = "";
        var suffix: []const u8 = "";
        if (std.mem.eql(u8, m_generic.ident, "Option")) {
            prefix = "?";
        } else if (std.mem.eql(u8, m_generic.ident, "Vec")) {
            prefix = "ArrayList(";
            suffix = ")";
        } else {
            // Unsupported generic type.
            i.* = type_from;
            return false;
        }

        if (is_pointer)
            _ = try writer.write("*");

        _ = try writer.write(prefix);
        try translateType(writer, toks, i, self_type);
        // Ensure that whole inner type has been translated.
        if (i.* != inner_type_from + inner_type_len)
            return ParserError.Other;
        _ = try writer.write(suffix);

        // Skip closing `>`.
        i.* += 1;

        return true;
    } else if (toks.match(i.*, "[")) |m_opening| {
        // Translate arrays and slices.
        // At this point we won't return `false`.
        i.* += m_opening.len;

        // This could be slice or array.
        switch (toks.tokens[i.* + try toks.typeLen(i.*, "; ]")]) {
            .@";" => {
                // In Rust array type is `[T; n]` but in Zig it's `[n]T`.
                // So we use buffer `buf` to delay writing `T` after `n`.
                var buf: [500]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                try translateType(fbs.writer(), toks, i, self_type);

                if (toks.match(i.*, "; size:num ]")) |m| {
                    if (is_pointer)
                        _ = try writer.write("*");
                    try writer.print("[{s}]{s}", .{ m.size, fbs.getWritten() });
                    i.* += m.len;
                } else {
                    // Expected tokens semicolon, length and closing bracket weren't found.
                    return ParserError.Other;
                }
            },
            .@"]" => {
                // Slice.
                // NOTE: We ignore `is_pointer` because slice is already a kind of pointer.
                _ = try writer.write("[]");
                try translateType(writer, toks, i, self_type);
                if (toks.match(i.*, "]")) |m|
                    i.* += m.len
                else
                    return ParserError.Other;
            },
            else => unreachable,
        }

        return true;
    } else if (toks.match(i.*, "name")) |m| {
        // Translate non-generic type without path.

        if (is_pointer)
            _ = try writer.write("*");
        if (std.mem.eql(u8, m.name, "Self")) {
            if (self_type) |range| {
                try writeTokens(writer, toks, range.from, range.to_excl);
            } else {
                try writer.print("{s}", .{m.name});
            }
        } else {
            try writer.print("{s}", .{m.name});
        }
        i.* += m.len;

        return true;
    } else {
        i.* = type_from;
        return false;
    }
}

fn translateTooComplexTypeHelper(writer: anytype, toks: Toks, i: *usize, allowed_token: ?Token) !void {
    while (i.* < toks.tokens.len) {
        if (toks.match(i.*, "(")) |_| {
            // Parens can contain comma. It appears in tuples like `(String, i32)`
            // or functions like `impl Fn(String, int32)`
            // or function pointers like `fn(i32, i32) -> i32`
            try translate(writer, toks, i, .@"(");
            try translateTooComplexTypeHelper(writer, toks, i, .@",");
            try translate(writer, toks, i, .@")");
        } else if (toks.match(i.*, "<")) |_| {
            // Angle brackets can contain comma. It appears when giving multiple generic arguments.
            try translate(writer, toks, i, .@"<");
            try translateTooComplexTypeHelper(writer, toks, i, .@",");
            try translate(writer, toks, i, .@">");
        } else if (toks.match(i.*, "[")) |_| {
            // Square brackets can contain semicolon. It appears in arrays.
            try translate(writer, toks, i, .@"[");
            try translateTooComplexTypeHelper(writer, toks, i, .@";");
            try translate(writer, toks, i, .@"]");
        } else if (toks.matchAny(i.*, &.{
            "_ident", "::", "static", "&", "'", "mut", "dyn", "impl", "for", "+", "->", "fn", "!",
        })) |m| {
            _ = try writer.write(" ");
            try writeTokens(writer, toks, i.*, i.* + m.len);
            i.* += m.len;
        } else if (allowed_token != null and toks.tokens[i.*] == allowed_token.?) {
            _ = try writer.write(" ");
            try writeTokens(writer, toks, i.*, i.* + 1);
            i.* += 1;
        } else {
            // We assume this is end of type.
            break;
        }
    }
}

fn translateTooComplexType(writer: anytype, toks: Toks, i: *usize) !void {
    _ = try writer.write("/* Ziggify: ");
    try translateTooComplexTypeHelper(writer, toks, i, null);
    _ = try writer.write("*/");
}

fn translateType(
    writer: anytype,
    toks: Toks,
    i: *usize,
    self_type: ?SelfTypeRange,
) (@TypeOf(writer).Error || ParserError || Allocator.Error)!void {
    if (!try translateSimpleType(writer, toks, i, self_type)) {
        try translateTooComplexType(writer, toks, i);
    }
}

fn consumePub(
    toks: Toks,
    i: *usize,
) bool {
    if (toks.matchEql(i.*, "pub ( crate )", .{ .crate = "crate" })) |m| {
        i.* += m.len;
        return true;
    } else if (toks.match(i.*, "pub")) |m| {
        i.* += m.len;
        return true;
    } else return false;
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
    } else if (toks.match(i.*, "struct name (")) |m| {
        try writer.print("const {s} = struct ", .{m.name});
        i.* += m.len - 1;
    } else return false;

    if (toks.match(i.*, "{")) |_| {
        // Struct struct.

        try translate(writer, toks, i, .@"{");
        _ = try writer.write("\n");

        while (i.* < toks.tokens.len) {
            // Process comment before field or attribute or before end of struct.
            try writeCommentBefore(writer, toks, i.*);

            // Ignore field visibility.
            _ = consumePub(toks, i);

            if (try skipAttribute(toks, i)) {
                //
            } else if (toks.match(i.*, "name :")) |m_field| {
                try writer.print("{s}: ", .{m_field.name});
                i.* += m_field.len;

                try translateType(writer, toks, i, null);
                try writer.print(",", .{});

                try writeCommentAfterOrNewLine(writer, toks, i.*);
            } else {
                // Field doesn't start here.
                break;
            }

            if (toks.match(i.*, ",")) |m_comma| {
                i.* += m_comma.len;
            }
        }

        try translate(writer, toks, i, .@"}");
        _ = try writer.write(";\n");
    } else if (toks.match(i.*, "(")) |m_opening| {
        // Tuple struct.

        _ = try writer.write("{\n");
        i.* += m_opening.len;

        // Translate types separated by comma.
        var field: usize = 0;
        while (i.* < toks.tokens.len and toks.tokens[i.*] != .@")") : (field += 1) {
            try writer.print("@\"{}\":", .{field});
            try translateType(writer, toks, i, null);
            try translateOptional(writer, toks, i, .@",");
        }

        if (toks.match(i.*, ");")) |m_closing| {
            _ = try writer.write("\n};\n");
            i.* += m_closing.len;
        } else return ParserError.Other;
    } else return ParserError.Other;

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
                if (toks.match(i.*, ",")) |m_comma| {
                    i.* += m_comma.len;
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

                        if (toks.match(i.*, ")")) |m_closing| {
                            i.* += m_closing.len;
                        } else return ParserError.ClosingBracketNotFound;

                        // Ignore optional comma after enum tuple item.
                        if (toks.match(i.*, ",")) |m_comma| {
                            i.* += m_comma.len;
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

                if (toks.match(i.*, ")")) |m_closing| {
                    i.* += m_closing.len;
                } else return ParserError.ClosingBracketNotFound;

                // Ignore optional comma after enum tuple item.
                if (toks.match(i.*, ",")) |m_comma| {
                    i.* += m_comma.len;
                }
                try writer.print(",\n", .{});
            }
        } else if (toks.match(i.*, "name {")) |m| {
            i.* += m.len;
            i.* += try toks.expressionLen(i.*, "}") + 1;
            // Ignore optional comma after enum struct item.
            if (toks.match(i.*, ",")) |m_comma| {
                i.* += m_comma.len;
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
                if (toks.match(i.*, "name :")) |m_field| {
                    try writer.print("{s}: ", .{m_field.name});
                    i.* += m_field.len;

                    try translateType(writer, toks, i, null);
                    try writer.print(",", .{});

                    // Ignore optional comma after struct field.
                    if (toks.match(i.*, ",")) |m_comma| {
                        i.* += m_comma.len;
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
            if (toks.match(i.*, ",")) |m_comma| {
                i.* += m_comma.len;
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
        } else if (toks.match(i.*, "use")) |m| {
            i.* += m.len;
            i.* += try toks.expressionLen(i.*, ";") + 1;
        } else if (toks.match(i.*, "const")) |m| {
            try writer.print("const ", .{});
            i.* += m.len;
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
        } else if (toks.match(i.*, "?")) |m| {
            // In Zig we use `try`. But it has to be placed before expression - not after it.
            // So translation would be hard. Instead we just ignore `?`
            // and let Zig compiler to show error.
            i.* += m.len;
        } else if (toks.matchAny(
            i.*,
            &.{
                "..=", "..", "==", "<=", "<",
                ">=",  ">",  ".",  "|",  "!",
                "&",   ",",  "*",  "/",  "%",
                "+",   "-",  ":",  "=",  "(",
                ")",   "as",
            },
        )) |m| {
            // Operators which are translated to themselves.
            //
            // Note that some of these translations are wrong.
            // Eg. `|` as a bitwise or is correctly translated to itself.
            // But `|` from lambda (eg. from `|t: f32| t <= 1.0 && t >= 0.0`)
            // can't be simply translated to Zig because Zig doesn't have lambdas
            // and translating it to itself is wrong.
            _ = try writer.write(" ");
            try writeTokens(writer, toks, i.*, i.* + m.len);
            _ = try writer.write(" ");
            i.* += m.len;
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
                } else if (toks.match(i.*, "name }")) |m_field| {
                    try writer.print(".{s} = {s}", .{ m_field.name, m_field.name });
                    i.* += m_field.len - 1; // Don't skip closing brace.
                } else if (toks.match(i.*, "name :")) |m_field| {
                    try writer.print(".{s} = ", .{m_field.name});
                    i.* += m_field.len;

                    const len_before = try toks.expressionLen(i.*, ", }");
                    try translateBody(writer, toks.restrict(i.* + len_before), i, self_type);

                    // Translate comma (if any).
                    try translateOptional(writer, toks, i, .@",");
                } else if (toks.match(i.*, "..")) |_| {
                    // Functional update syntax for structs.

                    const len = try toks.expressionLen(i.*, ", }");
                    _ = try writer.write("/* Ziggify: ");
                    try writeTokens(writer, toks, i.*, i.* + len);
                    i.* += len;

                    try translateOptional(writer, toks, i, .@",");
                    _ = try writer.write("*/");
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
            i.* += m.len;

            // Note it may happen that `{` belongs to struct construction and not to `for` body.
            const control_expression_len = try toks.expressionLen(i.*, "{");
            const enumerate_len = 8; // Length of `.iter().enumerate()`.

            // If expression after `in` ends with `.iter().enumerate()`.
            if (toks.matchEql(
                i.* + control_expression_len - enumerate_len,
                ".iter().enumerate()",
                .{ .iter = "iter", .enumerate = "enumerate" },
            )) |_| {
                _ = try writer.write("for (");

                // Translate expression after `in` except `.iter().enumerate()`.
                // We create `temp_toks` which doesn't contain `.iter().enumerate()`.
                const token_count = i.* + control_expression_len - enumerate_len;
                try translateBody(writer, toks.restrict(token_count), i, self_type);
                if (i.* != token_count) {
                    // Control expression not processed whole.
                    return ParserError.Other;
                }
                try writer.print(", 0..) |{s}, {s}|", .{ m.elem, m.index });
                i.* += enumerate_len; // Skip `.iter().enumerate()`.
            } else {
                _ = try writer.write("for (");
                const token_count = i.* + control_expression_len;
                try translateBody(writer, toks.restrict(token_count), i, self_type);
                if (i.* != token_count) {
                    // Control expression not processed whole.
                    return ParserError.Other;
                }
                try writer.print(") |/* Ziggify: ({s}, {s}) */|", .{ m.elem, m.index });
            }
        } else if (toks.match(i.*, "for")) |m| {
            // Handle other patterns in `for`.

            _ = try writer.write("for (");
            i.* += m.len;

            const pattern_from = i.*;
            const pattern_to_excl = i.* + try toks.expressionLen(i.*, "in");
            i.* = pattern_to_excl + 1; // Skip `in`.

            // Translate expression after `in` to the first `{`.
            // Note it may happen that `{` belongs to struct construction and not to `for` body.
            const control_expr_to_excl = i.* + try toks.expressionLen(i.*, "{");
            try translateBody(writer, toks.restrict(control_expr_to_excl), i, self_type);

            _ = try writer.write(") |/* Ziggify: ");
            try writeTokens(writer, toks, pattern_from, pattern_to_excl);
            _ = try writer.write("*/|");
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
        } else if (toks.match(i.*, "if")) |m| {
            try writeTokens(writer, toks, i.*, i.* + m.len);
            i.* += m.len;

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
        } else if (toks.match(i.*, "match")) |m| {
            _ = try writer.write("switch (");
            i.* += m.len;

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

                if (toks.match(i.*, "{")) |_| {
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
    if (toks.matchAny(i.*, &.{
        "fn name",
        // Functions which can be evaluated at compile time.
        // These in Zig don't need `const` or any other special flag.
        "const fn name",
    })) |m_fn| {
        if (public)
            try writer.print("pub fn ", .{})
        else
            try writer.print("fn ", .{});

        try writeInCamelCase(writer, m_fn.name);
        i.* += m_fn.len;

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
            if (toks.matchAny(
                i.*,
                &.{
                    // There may be comma or closing paren after the first param.
                    "name , ",
                    "name ) ",
                    "& name ,",
                    "& name )",
                },
            )) |m_param| {
                try writer.print("{s}: ", .{m_param.name});
                try writeTokens(writer, toks, range.from, range.to_excl);
                i.* += m_param.len;

                if (toks.tokens[i.* - 1] == .@",") {
                    _ = try writer.write(",");
                } else {
                    i.* -= 1; // Don't skip `)` token.
                }
            } else if (toks.matchAny(
                i.*,
                &.{
                    // There may be comma or closing paren after the first param.
                    "& mut name ,",
                    "& mut name )",
                },
            )) |m_param| {
                try writer.print("{s}: *", .{m_param.name});
                try writeTokens(writer, toks, range.from, range.to_excl);
                i.* += m_param.len;

                if (toks.tokens[i.* - 1] == .@",") {
                    _ = try writer.write(",");
                } else {
                    i.* -= 1; // Don't skip `)` token.
                }
            } else if (toks.matchAny(i.*, &.{
                // There may be comma or closing paren after the first param.
                "mut name ,",
                "mut name )",
            })) |m_param| {
                try writer.print("{s}: /* Ziggify: mut ownership */ ", .{m_param.name});
                try writeTokens(writer, toks, range.from, range.to_excl);
                i.* += m_param.len;

                if (toks.tokens[i.* - 1] == .@",") {
                    _ = try writer.write(",");
                } else {
                    i.* -= 1; // Don't skip `)` token.
                }
            }
        }

        while (i.* < toks.tokens.len) {
            if (toks.matchAny(i.*, &.{
                "name : & ' _lifetime mut",
                "name : & ' static mut",
                "name : & mut",
            })) |m_param| {
                try writer.print("{s}: *", .{m_param.name});
                i.* += m_param.len;

                try translateType(writer, toks, i, self_type);
            } else if (toks.match(i.*, "mut name :")) |m| {
                // This can either transfer ownership or be borrowed.
                try writer.print("{s}: /* Ziggify: mut param */ ", .{m.name});
                i.* += m.len;

                try translateType(writer, toks, i, self_type);
            } else if (toks.matchAny(
                i.*,
                &.{
                    "name : & ' _lifetime",
                    "name : & ' static",
                    "name : &",
                    "name :",
                },
            )) |m_param| {
                // Immutable param.

                // If this is immutable reference we don't want to translate it to pointer
                // and emit leading `*`. This is the reason why we can't use `translateType`
                // to translate whole parameter type and instead we skip reference before giving
                // the rest to `translateType`.
                try writer.print("{s}: ", .{m_param.name});
                i.* += m_param.len;

                try translateType(writer, toks, i, self_type);
            } else break;

            if (toks.match(i.*, ",")) |m_comma| {
                _ = try writer.write(",");
                i.* += m_comma.len;
            }

            // TODO: Read comment associated with a parameter (it's before or after? or both?).
        }

        if (toks.match(i.*, ")")) |m_closing| {
            _ = try writer.write(")");
            i.* += m_closing.len;
        } else {
            return ParserError.ClosingBracketNotFound;
        }

        // Translate optional return type.
        if (toks.match(i.*, "->")) |m_arrow| {
            i.* += m_arrow.len;
            // TODO: Instead of returning self return actual type.
            try translateType(writer, toks, i, self_type);
        } else {
            _ = try writer.write("void");
        }

        // Translate optional where clause - just wrap it in comment.
        if (toks.match(i.*, "where")) |_| {
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

fn translateThreadLocals(
    writer: anytype,
    toks: Toks,
    i: *usize,
    self_type: ?SelfTypeRange,
) !bool {
    if (toks.matchEql(i.*, "thread_local ! {", .{ .thread_local = "thread_local" })) |m| {
        i.* += m.len;
    } else return false;

    while (i.* < toks.tokens.len) {
        // Process comment before construct or before end of thread local block.
        try writeCommentBefore(writer, toks, i.*);

        if (toks.match(i.*, "static name :")) |m| {
            try writer.print("threadlocal var {s} : ", .{m.name});
            i.* += m.len;
            try translateType(writer, toks, i, self_type);
            try translate(writer, toks, i, .@"=");

            const len = try toks.expressionLen(i.*, ";");
            try translateBody(writer, toks.restrict(i.* + len), i, self_type);
            try translate(writer, toks, i, .@";");
            _ = try writer.write("\n");
        } else break;
    }

    if (toks.match(i.*, "}")) |m| {
        i.* += m.len;
    } else return ParserError.ClosingBracketNotFound;

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

        const public = consumePub(toks, i);

        if (try skipAttribute(toks, i)) {
            //
        } else if (toks.match(i.*, "use")) |m| {
            i.* += m.len;
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
        } else if (toks.match(i.*, "type name = ")) |m| {
            try writer.print("const {s} = ", .{m.name});
            i.* += m.len;

            const right_side_len = try toks.typeLen(i.*, ";");
            try translateType(writer, toks.restrict(i.* + right_side_len), i, self_type);

            try translate(writer, toks, i, .@";");
            _ = try writer.write("\n");
        } else if (try translateThreadLocals(writer, toks, i, self_type)) {
            //
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

            if (toks.match(i.*, "}")) |m_closing| {
                i.* += m_closing.len;
            } else return ParserError.ClosingBracketNotFound;
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
        "test-data/egui-window.rs",
        "test-data/egui-context.rs",
    };
    const paths_tokenized_expected = [_][]const u8{
        "test-data/epaint-bezier.tokenized",
        "test-data/epaint-shape.tokenized",
        "test-data/egui-window.tokenized",
        "test-data/egui-context.tokenized",
    };
    const paths_tokenized_actual = [_][]const u8{
        "tmp/epaint-bezier.tokenized",
        "tmp/epaint-shape.tokenized",
        "tmp/egui-window.tokenized",
        "tmp/egui-context.tokenized",
    };
    const paths_translated_expected = [_][]const u8{
        "test-data/epaint-bezier.translated",
        "test-data/epaint-shape.translated",
        "test-data/egui-window.translated",
        "test-data/egui-context.translated",
    };
    const paths_translated_actual = [_][]const u8{
        "tmp/epaint-bezier.translated",
        "tmp/epaint-shape.translated",
        "tmp/egui-window.translated",
        "tmp/egui-context.translated",
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
