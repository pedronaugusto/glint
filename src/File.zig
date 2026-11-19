//! Owned immutable front-end input. AST spans supplement, never replace, std ZIR.
const std = @import("std");
const aegis = @import("aegis");
const File = @This();

arena: std.heap.ArenaAllocator,
source: [:0]const u8,
tree: std.zig.Ast,
zir: ?std.zig.Zir,
status: Status,
comments: []const Comment,
lines: []const u32,
/// The source's length: every position in it is at most this.
end: u32,

pub const Status = enum { parsed, invalid_syntax, invalid_lowering, budget_exhausted };
/// What the bytes are, as the caller states it: Zig source, or ZON data (`build.zig.zon`, a
/// `@import("x.zon")`), which std parses as one expression and AstGen never lowers.
pub const Kind = std.zig.Ast.Mode;
pub const Limits = struct {
    bytes: usize = 16 * 1024 * 1024,
    nodes: usize = 1_000_000,
    instructions: usize = 2_000_000,
    nesting: usize = 256,
    expression_tokens: usize = 1024,
};
pub const Comment = struct { start: u32, end: u32, line: u32 };
pub const InitError = std.mem.Allocator.Error || error{ SourceTooLarge, SourceTooComplex };

pub fn init(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) InitError!File {
    return initWithLowering(gpa, bytes, limits, true, .zig);
}

/// The file `bytes` are, read as `kind` says. A ZON file is parsed and checked as ZON, never
/// lowered: it has no ZIR, and its status is `parsed`, or `invalid_syntax` where it is not ZON.
pub fn initWithLowering(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits, lower: bool, kind: Kind) InitError!File {
    if (bytes.len > limits.bytes or bytes.len > std.math.maxInt(u32)) return error.SourceTooLarge;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const source = try a.dupeSentinel(u8, bytes, 0);
    const front = try aegis.input.Untrusted([:0]const u8).init(source).parse(Reading{ .a = a, .limits = limits, .kind = kind }, parseSource);
    const tree = front.tree;
    var status: Status = if (tree.errors.len == 0) .parsed else .invalid_syntax;
    var zir: ?std.zig.Zir = null;
    if (bytes.len > limits.bytes or tree.nodes.len > limits.nodes) {
        status = .budget_exhausted;
    } else if (status == .parsed and !safeLiterals(&tree)) {
        // ZON is never lowered: such a literal is a file std's ZON reader rejects.
        status = if (kind == .zon) .invalid_syntax else .invalid_lowering;
    } else if (status == .parsed and kind == .zon) {
        // std's parser takes any expression in ZON mode; std's ZON reader refuses what ZON is
        // not (a call, a name, a declaration), as the compiler does. So a ZON file that parses
        // holds data alone, and nothing in it is code.
        const zoir = try std.zig.ZonGen.generate(a, tree, .{});
        if (zoir.hasCompileErrors()) status = .invalid_syntax;
    } else if (status == .parsed and lower) {
        zir = try std.zig.AstGen.generate(a, tree);
        if (zir.?.hasCompileErrors()) status = .invalid_lowering;
        if (zir.?.instructions.len > limits.instructions) status = .budget_exhausted;
    }
    return .{ .arena = arena, .source = source, .tree = tree, .zir = zir, .status = status, .lines = front.lines, .comments = front.comments, .end = front.end };
}

/// What a file's bytes are once read as Zig or ZON, and the input boundary of all glint builds
/// from them: the tree, each line's start and each comment's span.
const Front = struct { tree: std.zig.Ast, lines: []const u32, comments: []const Comment, end: u32 };
const Reading = struct { a: std.mem.Allocator, limits: Limits, kind: Kind };

/// The check is std's parser, in the mode the caller states, behind the lexical budget that
/// keeps its work bounded: every node and token index its tree holds indexes the tree's own
/// tables, and every line start and comment span this scan records is a position in the source. What the rules read of
/// them is the tree's, not a peer's choice.
fn parseSource(reading: Reading, source: [:0]const u8) InitError!Front {
    try sourceComplexity(source, reading.limits);
    const tree = try std.zig.Ast.parse(reading.a, source, .{ .mode = reading.kind });
    var lines: std.ArrayList(u32) = .empty;
    try lines.append(reading.a, 0);
    for (source, 0..) |byte, offset| if (byte == '\n') {
        try lines.append(reading.a, @intCast(offset + 1));
    };
    const comments = try scanComments(reading.a, source, lines.items);
    const end = aegis.int.cast(u32, source.len) catch return error.SourceTooLarge;
    return .{ .tree = tree, .lines = try lines.toOwnedSlice(reading.a), .comments = comments, .end = end };
}

// Literals std's lowering (AstGen, ZonGen) reads with an unwrap it assumes the parser already
// checked. Check their exact tokens before lowering, including what the parser accepts:
// - a char literal's lowering assumes a complete UTF-8 sequence, and the parser takes cut bytes;
// - a float's lowering unwraps std.fmt.parseFloat, and std.zig.parseNumberLiteral calls a hex
//   float with no digit before its exponent (`0x.p1`) a float that parseFloat refuses;
// - parseFloat itself misreads a decimal float's underscores on its slow path (`0.0_05e94`
//   overflows an i32 in it), so such a literal is refused before parseFloat runs at all.
fn safeLiterals(tree: *const std.zig.Ast) bool {
    for (tree.tokens.items(.tag), 0..) |tag, i| switch (tag) {
        .char_literal => {
            const raw = tree.tokenSlice(@intCast(i));
            if (raw.len < 3 or raw[0] != '\'' or raw[raw.len - 1] != '\'') return false;
            if (raw[1] != '\\' and !std.unicode.utf8ValidateSlice(raw[1 .. raw.len - 1])) return false;
        },
        .number_literal => {
            const raw = tree.tokenSlice(@intCast(i));
            if (std.zig.parseNumberLiteral(raw) != .float) continue;
            if (!underscoresReadAsDigits(raw)) return false;
            _ = std.fmt.parseFloat(f128, raw) catch return false;
        },
        else => {},
    };
    return true;
}

/// Whether std's `parseFloat(f128, raw)`, given the token with its underscores as AstGen gives it,
/// reads the decimal float `raw` as it reads the same digits without them. Zig 0.17's slow path
/// (`Decimal.parse`) does not always: past an underscore it records zeros it means to skip, and it
/// trims trailing zeros by an index that leaves the underscores out, so `0.0_05e94` becomes a decimal
/// of zero digits whose shift loop never ends (an i32 overflow), and `1.0_05e94` is read as 1.00e94.
/// Its fast path reads underscores right, so only a literal the fast path declines is compared: the
/// value of the decimal std builds from the token against the one it builds from the digits alone.
/// Where they differ the literal is refused, even where the f128 happens to round the same (seen
/// only past 34 significant digits or a decimal exponent of 400). A hex float never reaches
/// `Decimal.parse`; a literal over 1024 bytes on the slow path is refused unread.
fn underscoresReadAsDigits(raw: []const u8) bool {
    if (std.mem.findScalar(u8, raw, '_') == null) return true;
    if (raw.len >= 2 and raw[0] == '0' and (raw[1] | 0x20) == 'x') return true;
    if (fastF128(raw)) return true;
    var buffer: [1024]u8 = undefined;
    if (raw.len > buffer.len) return false;
    var len: usize = 0;
    for (raw) |c| if (c != '_') {
        buffer[len] = c;
        len += 1;
    };
    const with = decimalValue(raw, decimalShape(raw) orelse return false) orelse return false;
    const without = decimalValue(raw, decimalShape(buffer[0..len]) orelse return false) orelse return false;
    return std.meta.eql(with, without);
}

/// The value a decimal shape of `raw`'s digits holds, by its first and last nonzero digit (counted
/// among the digits before the exponent) and the point measured from the first; zeros at either end
/// of the kept digits change nothing. null where it keeps digits that are all zeros: std's slow path
/// tells zero by a count of no digits, and shifts such a decimal forever.
const DecimalValue = struct { first: usize, last: usize, point: i64, truncated: bool };

fn decimalValue(raw: []const u8, shape: DecimalShape) ?DecimalValue {
    if (shape.digits == 0) return .{ .first = 0, .last = 0, .point = 0, .truncated = shape.truncated };
    var first: ?usize = null;
    var last: usize = 0;
    var index: usize = 0;
    for (raw) |c| switch (c) {
        '0'...'9' => {
            if (index >= shape.skipped + shape.digits) break;
            if (index >= shape.skipped and c != '0') {
                if (first == null) first = index;
                last = index;
            }
            index += 1;
        },
        '_', '.' => {},
        else => break,
    };
    const start = first orelse return null;
    return .{ .first = start, .last = last, .point = shape.point - @as(i64, @intCast(start - shape.skipped)), .truncated = shape.truncated };
}

/// Whether std's parseFloat reads the decimal float `raw` into an f128 on its fast path
/// (parse.zig's `parseNumber`, convert_fast.zig's `convertFast`): at most 38 significant digits,
/// a decimal exponent from -48 to 48, or to 82 where the mantissa times the excess power of ten
/// still has no more than 114 bits. Underscores pass, as std's digit scan passes them.
fn fastF128(raw: []const u8) bool {
    const max_mantissa_digits = 38;
    const max_mantissa: u128 = 2 << 112;
    var mantissa: u128 = 0;
    var count: usize = 0;
    var fraction: i64 = 0;
    var point = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) switch (raw[i]) {
        '0'...'9' => |c| {
            mantissa = mantissa *% 10 +% (c - '0');
            count += 1;
            if (point) fraction += 1;
        },
        '_' => {},
        '.' => point = true,
        else => break,
    };
    var exponent: i64 = -fraction;
    if (i < raw.len and (raw[i] | 0x20) == 'e') {
        i += 1;
        var negative = false;
        if (i < raw.len and (raw[i] == '-' or raw[i] == '+')) {
            negative = raw[i] == '-';
            i += 1;
        }
        var written: i64 = 0;
        while (i < raw.len) : (i += 1) switch (raw[i]) {
            '0'...'9' => |c| if (written < 0x1000_0000) {
                written = 10 * written + (c - '0');
            },
            '_' => {},
            else => break,
        };
        exponent += if (negative) -written else written;
    }
    if (count > max_mantissa_digits) {
        // std recounts the excess past the leading zeros (the bytes `0`, `.` and `_` before any other).
        var excess = count - max_mantissa_digits;
        for (raw) |c| switch (c) {
            '0' => excess -|= 1,
            '.', '_' => {},
            else => break,
        };
        if (excess > 0) return false;
    }
    if (exponent < -48 or exponent > 82 or mantissa > max_mantissa) return false;
    if (exponent <= 48) return true;
    const scaled = std.math.mul(u128, mantissa, std.math.powi(u128, 10, @intCast(exponent - 48)) catch return false) catch return false;
    return scaled <= max_mantissa;
}

/// The decimal std 0.17's `Decimal.parse` builds from `s`, by what decides it: how many leading digits
/// it skips, how many it keeps, where its point is, and whether it truncated. null where `parse`
/// itself traps (a count trimmed below zero, an index run past the start).
const DecimalShape = struct { skipped: usize, digits: usize, point: i64, truncated: bool };

fn decimalShape(s: []const u8) ?DecimalShape {
    const max_digits = 11564;
    if (s.len > std.math.maxInt(i32)) return null;
    var offset: usize = 0;
    var underscores: usize = 0;
    var skipped: usize = 0;
    // `skipChars("0_")` passes underscores without counting them, unlike the digit scan.
    while (offset < s.len and (s[offset] == '0' or s[offset] == '_')) : (offset += 1) {
        if (s[offset] == '0') skipped += 1;
    }
    var digits: usize = 0;
    scanDigits(s, &offset, &underscores, &digits);
    var point: i64 = 0;
    if (offset < s.len and s[offset] == '.') {
        offset += 1;
        const marker = offset - underscores;
        if (digits == 0) while (offset < s.len and s[offset] == '0') : (offset += 1) {
            skipped += 1;
        };
        scanDigits(s, &offset, &underscores, &digits);
        point = @as(i64, @intCast(marker)) - @as(i64, @intCast(offset - underscores));
    }
    var truncated = false;
    if (digits != 0) {
        // Trailing zeros, read at the offset that leaves the underscores out, as std reads them.
        var trailing: usize = 0;
        var i = offset - underscores - 1;
        while (true) {
            if (s[i] == '0') {
                trailing += 1;
            } else if (s[i] != '.') break;
            if (i == 0) return null;
            i -= 1;
            if (i == 0) break;
        }
        point += @intCast(trailing);
        digits = std.math.sub(usize, digits, trailing) catch return null;
        point += @intCast(digits);
        if (digits > max_digits) {
            truncated = true;
            digits = max_digits;
        }
    }
    if (offset < s.len and (s[offset] | 0x20) == 'e') {
        offset += 1;
        var negative = false;
        if (offset < s.len and (s[offset] == '-' or s[offset] == '+')) {
            negative = s[offset] == '-';
            offset += 1;
        }
        var written: i64 = 0;
        while (offset < s.len) : (offset += 1) switch (s[offset]) {
            '0'...'9' => |c| if (written < 0x10000) {
                written = 10 * written + (c - '0');
            },
            '_' => {},
            else => break,
        };
        point += if (negative) -written else written;
    }
    return .{ .skipped = skipped, .digits = digits, .point = point, .truncated = truncated };
}

/// std's digit scan: digits counted, underscores passed and counted.
fn scanDigits(s: []const u8, offset: *usize, underscores: *usize, digits: *usize) void {
    while (offset.* < s.len) : (offset.* += 1) switch (s[offset.*]) {
        '0'...'9' => digits.* += 1,
        '_' => underscores.* += 1,
        else => return,
    };
}

fn sourceComplexity(source: [:0]const u8, limits: Limits) InitError!void {
    // Lexical resource budgets, not syntax or type judgments. They keep std's
    // recursive parse/lowering work bounded even on malformed input.
    var lexer: std.zig.Tokenizer = .init(source);
    var depth: usize = 0;
    var expression: usize = 0;
    while (true) {
        const token = lexer.next();
        if (token.tag == .eof) return;
        switch (token.tag) {
            .l_paren, .l_bracket, .l_brace => {
                depth += 1;
                if (depth > limits.nesting) return error.SourceTooComplex;
                expression = 0;
            },
            .r_paren, .r_bracket, .r_brace => {
                depth -|= 1;
                expression = 0;
            },
            .semicolon, .comma => expression = 0,
            .doc_comment, .container_doc_comment => {},
            else => {
                expression += 1;
                if (expression > limits.expression_tokens) return error.SourceTooComplex;
            },
        }
    }
}

pub fn deinit(self: *File) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Where line `l` ends: the next line's start, past its newline, or the source's end.
pub fn lineEnd(self: *const File, l: usize) u32 {
    const next = l +| 1;
    return if (next < self.lines.len) self.lines[next] else self.end;
}

/// Line `l`: where it starts, and its bytes, its newline and a carriage return before it left
/// out. Empty past the last line.
pub fn lineBytes(self: *const File, l: usize) struct { start: u32, text: []const u8 } {
    if (l >= self.lines.len) return .{ .start = self.end, .text = "" };
    const start = self.lines[l];
    const end = self.lineEnd(l);
    if (start > end or end > self.source.len) return .{ .start = start, .text = "" };
    const whole = self.source[start..end];
    const bare = std.mem.cutSuffix(u8, whole, "\n") orelse whole;
    return .{ .start = start, .text = std.mem.cutSuffix(u8, bare, "\r") orelse bare };
}

/// The 1-based column of `offset` on its line.
pub fn column(self: *const File, offset: u32) u32 {
    const l = self.line(offset);
    if (l >= self.lines.len) return 1;
    const start = self.lines[l];
    return if (offset < start) 1 else (offset - start) +| 1;
}

pub fn line(self: *const File, offset: u32) u32 {
    return lineIndex(self.lines, offset);
}

fn lineIndex(lines: []const u32, offset: u32) u32 {
    var lo: usize = 0;
    var hi = lines.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (lines[mid] <= offset) lo = mid + 1 else hi = mid;
    }
    return @intCast(lo - 1);
}

fn scanComments(a: std.mem.Allocator, source: [:0]const u8, lines: []const u32) InitError![]const Comment {
    var result: std.ArrayList(Comment) = .empty;
    var lexer: std.zig.Tokenizer = .init(source);
    var end: usize = 0;
    while (true) {
        const token = lexer.next();
        // Ordinary comments are gaps in the real tokenizer. Strings, character
        // literals and multiline-string lines have token spans and are skipped.
        var cursor = end;
        while (cursor < token.loc.start) {
            if (source[cursor] == '/' and cursor + 1 < token.loc.start and source[cursor + 1] == '/') {
                const start = cursor;
                while (cursor < token.loc.start and source[cursor] != '\n') cursor += 1;
                try result.append(a, .{ .start = @intCast(start), .end = @intCast(cursor), .line = lineIndex(lines, @intCast(start)) });
            } else cursor += 1;
        }
        if (token.tag == .doc_comment or token.tag == .container_doc_comment) {
            try result.append(a, .{ .start = @intCast(token.loc.start), .end = @intCast(token.loc.end), .line = lineIndex(lines, @intCast(token.loc.start)) });
        }
        end = token.loc.end;
        if (token.tag == .eof) break;
    }
    return result.toOwnedSlice(a);
}

test "front end lowers through std ZIR and retains lazy declarations" {
    var file = try init(std.testing.allocator, "const unused = struct { const value: u8 = 1; };", .{});
    defer file.deinit();
    try std.testing.expectEqual(Status.parsed, file.status);
    try std.testing.expect(file.zir.?.instructions.len > 0);
}

test "front end invalid syntax and lowering are distinct" {
    var syntax = try init(std.testing.allocator, "const x = ;", .{});
    defer syntax.deinit();
    try std.testing.expectEqual(Status.invalid_syntax, syntax.status);
    try std.testing.expectEqual(null, syntax.zir);
    var lowering = try init(std.testing.allocator, "fn f(x: u8) void {}", .{});
    defer lowering.deinit();
    try std.testing.expectEqual(Status.invalid_lowering, lowering.status);
}

test "comment parser rejects string lookalikes" {
    var file = try init(std.testing.allocator, "const s = \"// fake: a comment in a string\"; // real\n// next\n", .{});
    defer file.deinit();
    try std.testing.expectEqual(@as(usize, 2), file.comments.len); // safe: explicit compile-time type selection; the value is representable in that type.
    try std.testing.expectEqualStrings("// real", file.source[file.comments[0].start..file.comments[0].end]);
}

test "front end rejects bytes before parsing beyond the caller budget" {
    try std.testing.expectError(error.SourceTooLarge, init(std.testing.allocator, "pub const x = 1;", .{ .bytes = 4 }));
}

test "front end rejects excessive nesting and expression work before std recursion" {
    const a = std.testing.allocator;
    const nested = try a.alloc(u8, 257);
    defer a.free(nested);
    @memset(nested, '(');
    try std.testing.expectError(error.SourceTooComplex, init(a, nested, .{}));
    const chain = try a.alloc(u8, 1025);
    defer a.free(chain);
    @memset(chain, '!');
    try std.testing.expectError(error.SourceTooComplex, init(a, chain, .{}));
}

test "morning cut UTF8 character literal never reaches unsafe std lowering" {
    const bytes = "const c = '\xe2';";
    var file = try init(std.testing.allocator, bytes, .{});
    defer file.deinit();
    try std.testing.expect(file.status != .parsed);
}

test "a ZON file is parsed and checked as ZON, never lowered" {
    var data = try initWithLowering(std.testing.allocator, ".{ .bytes = .{ 1, 2 }, .name = \"k\" }", .{}, true, .zon);
    defer data.deinit();
    try std.testing.expectEqual(Status.parsed, data.status);
    try std.testing.expectEqual(null, data.zir);
    try std.testing.expectEqual(Kind.zon, data.tree.mode);
    // A syntax error, and an expression ZON is not (a call std's parser takes), are refused alike.
    var syntax = try initWithLowering(std.testing.allocator, ".{ .bytes = }", .{}, true, .zon);
    defer syntax.deinit();
    try std.testing.expectEqual(Status.invalid_syntax, syntax.status);
    var code = try initWithLowering(std.testing.allocator, "f(1)", .{}, true, .zon);
    defer code.deinit();
    try std.testing.expectEqual(Status.invalid_syntax, code.status);
    try std.testing.expectEqual(null, code.zir);
}
