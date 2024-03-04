const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.io.Writer;

const Token = enum {
    // Keywords.
    kw_mod,
    kw_pub,
    kw_use,
    kw_struct,
    kw_union,
    kw_fn,
    kw_where,
    kw_trait,
    kw_impl,
    kw_for,
    kw_if,
    kw_else,
    kw_match,
    kw_let,
    kw_mut,

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
    /// By default identifier matches identifier but optional kinds `:str` and `:num`
    /// after the identifier make it match string or number.
    ///
    /// Identifiers which don't start by underscore capture `token_data`.
    /// Structs returned by `Toks.match` have fields with captured `token_data`.
    /// These fields are named after identifiers in the original pattern.
    fn parsePattern(comptime pattern: []const u8) Pattern {
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
                    return count + 1;
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

    /// Counts number of tokens to the first `stop` token (including the stop token).
    /// Stop tokens inside brackets are ignored.
    fn bracketedCountUntilAny(self: Toks, i: usize, stop: []const Token) ParserError!usize {
        return self.genericBracketedCountUntilAny(
            i,
            &.{ .@"(", .@"[", .@"{" },
            &.{ .@")", .@"]", .@"}" },
            stop,
        );
    }

    fn bracketedCountUntil(self: Toks, i: usize, stop: Token) ParserError!usize {
        return bracketedCountUntilAny(self, i, &.{stop});
    }

    /// Counts number of tokens to the first `stop` token (including the stop token).
    /// Stop tokens inside brackets are ignored.
    fn bracketedCountWithAngleBracketsUntilAny(self: Toks, i: usize, stop: []const Token) ParserError!usize {
        return self.genericBracketedCountUntilAny(
            i,
            &.{ .@"(", .@"[", .@"{", .@"<" },
            &.{ .@")", .@"]", .@"}", .@">" },
            stop,
        );
    }

    fn bracketedCountWithAngleBracketsUntil(self: Toks, i: usize, stop: Token) ParserError!usize {
        return bracketedCountWithAngleBracketsUntilAny(self, i, &.{stop});
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
        } else if (getOperator(data)) |operator| {
            data = data[operator.str.len..];
            try s.addToken(operator.token);
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

fn readStructsAndTheirFields(
    toks: Toks,
    allocator: Allocator,
) (ParserError || Allocator.Error)!Structs {
    var s = StructReaderSate.init(allocator);
    defer s.deinit();

    var i: usize = 0;

    readStructsAndTheirFieldsInModule(&s, toks, &i) catch |err| {
        // Reports tokens where error ocurred.
        std.debug.print("Error {} while reading structs {any}\n", .{
            err,
            if (toks.tokens[i..].len < 20) toks.tokens[i..] else toks.tokens[i..][0..20],
        });
        return err;
    };

    if (i < toks.tokens.len) {
        // Reports tokens where error ocurred.
        std.debug.print("Reading structs finished prematurely {any}\n", .{
            if (toks.tokens[i..].len < 20) toks.tokens[i..] else toks.tokens[i..][0..20],
        });
        return ParserError.Other;
    }

    return s.toStructs();
}

fn readStructsAndTheirFieldsInModule(
    s: *StructReaderSate,
    toks: Toks,
    i: *usize,
) (ParserError || Allocator.Error)!void {
    while (i.* < toks.tokens.len) {
        const public = toks.tokens[i.*] == .kw_pub;
        if (public) {
            i.* += 1;
        }

        if (toks.startsWith(i.*, &.{ .@"#", .@"!", .@"[" })) |len| {
            i.* += len;
            i.* += try toks.bracketedCountUntil(i.*, .@"]");
        } else if (toks.startsWith(i.*, &.{ .@"#", .@"[" })) |len| {
            i.* += len;
            i.* += try toks.bracketedCountUntil(i.*, .@"]");
        } else if (toks.startsWith(i.*, &.{.kw_use})) |len| {
            i.* += len;
            i.* += try toks.bracketedCountUntil(i.*, .@";");
        } else if (toks.startsWithAny(i.*, &.{ &.{.kw_impl}, &.{.kw_fn} })) |len| {
            i.* += len;
            i.* += try toks.bracketedCountUntil(i.*, .@"{");
            i.* += try toks.bracketedCountUntil(i.*, .@"}");
        } else if (toks.startsWith(i.*, &.{ .kw_mod, .d_ident, .@"{" })) |len| {
            i.* += len;
            try readStructsAndTheirFieldsInModule(s, toks, i);

            if (i.* < toks.tokens.len and toks.tokens[i.*] == .@"}") {
                i.* += 1;
            } else {
                return ParserError.ClosingBracketNotFound;
            }
        } else if (toks.startsWithAndGetData(i.*, &.{ .kw_struct, .d_ident, .@"{" })) |ld| {
            const struct_name = ld.data;
            try s.structs.append(.{
                .public = public,
                .name = struct_name,
                .fields_from = s.fields.items.len,
                .fields_to_excl = s.fields.items.len,
            });
            i.* += ld.len;
            while (true) {
                // Skip public modifier.
                const public_field = i.* < toks.tokens.len and toks.tokens[i.*] == .kw_pub;
                if (public_field) {
                    i.* += 1;
                }

                if (toks.startsWithAndGetData(i.*, &.{ .d_ident, .@":" })) |ld2| {
                    const field_name = ld2.data;
                    try s.fields.append(.{ .name = field_name });
                    s.structs.items[s.structs.items.len - 1].fields_to_excl += 1;

                    // Skip type.
                    i.* += try toks.bracketedCountUntilAny(i.*, &.{ .@",", .@"}" }) - 1;

                    if (i.* < toks.tokens.len and toks.tokens[i.*] == .@",") {
                        i.* += 1;
                    } else {
                        break; // We must stop reading fields.
                    }
                } else if (public_field) {
                    // We read `pub` which is not followed by field.
                    return ParserError.Other;
                } else {
                    break;
                }
            }

            if (i.* < toks.tokens.len and toks.tokens[i.*] == .@"}")
                i.* += 1
            else
                return ParserError.ClosingBracketNotFound; // Module is not closed by brace.
        } else {
            // Probably end of module.
            return;
        }
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

    const structs = try readStructsAndTheirFields(toks, allocator);
    defer structs.deinit(allocator);

    // Print structures and their fields.
    for (structs.structs) |s| {
        std.debug.print("Struct {s}\n", .{s.name});
        for (s.fields_from..s.fields_to_excl) |i| {
            const field = structs.fields[i];
            std.debug.print("    Field {s}\n", .{field.name});
        }
    }
}
