//! Fast source facts from Zig's standard tokenizer. No AST, ZIR or module mapping.
const std = @import("std");
const liveness = @import("Token/liveness.zig");
const StoredToken = @import("Token/store.zig").Token;

const data = @import("Token/data.zig");
pub const Token = data.Token;
pub const Observer = data.Observer;
pub const Import = data.Import;
pub const Unsupported = data.Unsupported;
pub const Range = data.Range;
pub const Facts = data.Facts;
pub const Error = data.Error;

/// Allocates source/token/output storage in the caller's arena. Output owns no allocator.
/// Import facts are in import-token order, then alias-member use order. The base edge
/// precedes its direct member edge. Tests are disjoint inclusive byte-offset ranges.
/// This is conservative lexical liveness, not declaration or type resolution.
pub fn scan(arena: std.mem.Allocator, source: []const u8, seen: ?Observer) Error!Facts {
    if (source.len > std.math.maxInt(u29)) return error.SourceTooLarge;
    return scanSentinel(arena, try arena.dupeSentinel(u8, source, 0), seen);
}
/// Avoids copying bytes when the source provider already owns a zero sentinel.
/// The caller keeps source alive as long as the returned token and spelling slices.
pub fn scanSentinel(arena: std.mem.Allocator, source: [:0]const u8, seen: ?Observer) Error!Facts {
    if (source.len > std.math.maxInt(u29)) return error.SourceTooLarge;
    var facts = if (source.len <= 1024) try scanBuilt(true, arena, source, null) else try scanBuilt(false, arena, source, null);
    if (seen != null) facts.tokens = try lexSentinel(arena, source, seen);
    return facts;
}
fn scanBuilt(comptime small: bool, arena: std.mem.Allocator, source: [:0]const u8, seen: ?Observer) Error!Facts {
    var builder: liveness.Builder(small) = .{};
    var buffer: [if (small) 2048 else 0]u8 = undefined;
    var storage: std.heap.BufferFirstAllocator = .init(&buffer, arena);
    const ts = try tokenize(arena, if (small) storage.allocator() else arena, source, seen, &builder);
    return recoverShaped(arena, source, ts, try builder.finish(arena, ts));
}

/// Token sequence only, using the same standard tokenizer and observer contract.
pub fn lexSentinel(arena: std.mem.Allocator, source: [:0]const u8, seen: ?Observer) Error![]const Token {
    if (source.len > std.math.maxInt(u29)) return error.SourceTooLarge;
    return tokenize(arena, arena, source, seen, {});
}

fn tokenize(arena: std.mem.Allocator, storage: std.mem.Allocator, source: [:0]const u8, seen: ?Observer, builder: anytype) Error![]if (@TypeOf(builder) == void) Token else StoredToken {
    const bytes = source;
    var lexer = std.zig.Tokenizer.init(bytes);
    const Element = if (@TypeOf(builder) == void) Token else StoredToken;
    var out: std.ArrayList(Element) = .empty;
    try out.ensureTotalCapacityPrecise(storage, if (source.len < 1024) @min(source.len / 2 + 4, 32) else @min(source.len / 4 + 4, 512));
    while (true) {
        const token = lexer.next();
        const raw = bytes[token.loc.start..token.loc.end];
        switch (token.tag) {
            .eof => break,
            .doc_comment, .container_doc_comment => {},
            .char_literal, .multiline_string_literal_line, .invalid => {
                if (seen) |observer| if (observer.boundary) |boundary| boundary(observer.context);
            },
            .string_literal => {
                const text = if (raw.len >= 2) raw[1 .. raw.len - 1] else raw;
                try emit(storage, &out, initToken(Element, .string_literal, .string, text, token.loc.start, token.loc.end), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
            },
            .identifier, .number_literal => {
                const escaped = std.mem.startsWith(u8, raw, "@\"");
                const text = if (escaped) try std.zig.string_literal.parseAlloc(arena, raw[1..]) else raw;
                const stored = if (Element != Token and escaped) Element.initEscaped(text, token.loc.start, token.loc.end) else initToken(Element, token.tag, if (token.tag == .number_literal) .literal else .word, text, token.loc.start, token.loc.end);
                try emit(storage, &out, stored, seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
            },
            .builtin => {
                try emit(storage, &out, initToken(Element, .builtin, .punctuation, raw[0..1], token.loc.start, token.loc.start + 1), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
                try emit(storage, &out, initToken(Element, .identifier, .word, raw[1..], token.loc.start + 1, token.loc.end), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
            },
            else => {
                if (@backingInt(token.tag) >= @backingInt(std.zig.Token.Tag.keyword_addrspace)) { // safe: standard keyword tags form the final contiguous enum group.
                    try emit(storage, &out, initToken(Element, token.tag, .keyword, raw, token.loc.start, token.loc.end), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
                } else if (seen == null and raw.len != 0 and raw[0] != '.') {
                    try emit(storage, &out, initToken(Element, token.tag, .punctuation, raw, token.loc.start, token.loc.end), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
                } else for (raw, 0..) |_, i| {
                    // Ranges retain distinct dots. Policy observers receive every punctuation
                    // byte; ordinary graph scans can keep other std operators compact.
                    try emit(storage, &out, initToken(Element, if (raw[i] == '.') .period else .asterisk, .punctuation, raw[i .. i + 1], token.loc.start + i, token.loc.start + i + 1), seen, source.len); // safe: checked source length bounds std tokenizer byte offsets below u32.
                }
            },
        }
        // The std tag tells us which tokens can change structural state. Ordinary
        // identifiers/numbers need no second string dispatch during emission.
        if (@TypeOf(builder) != void) switch (token.tag) {
            .keyword_test, .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace => try builder.token(arena, out.items[out.items.len - 1], out.items),
            .identifier => if (out.items[out.items.len - 1].is("is_test")) try builder.token(arena, out.items[out.items.len - 1], out.items),
            .builtin => if (std.mem.eql(u8, raw, "@import")) try builder.imported(arena, out.items.len - 2),
            else => {},
        };
    }
    return out.toOwnedSlice(storage);
}
inline fn emit(arena: std.mem.Allocator, out: anytype, token: anytype, seen: ?Observer, total: usize) Error!void {
    if (out.items.len == out.capacity) {
        if (out.items.len < 512) {
            try out.ensureUnusedCapacity(arena, 1);
        } else {
            const n = out.items.len;
            const projected = @as(u128, n) * total / @max(token.end(), 1); // safe: widening preserves the source-bounded token count.
            const capacity = @min(@max(projected, n + n / 2 + 16), 4 * n + 16);
            try out.ensureTotalCapacityPrecise(arena, @intCast(capacity)); // safe: capped at four times a source-bounded token count within usize.
        }
    }
    out.appendAssumeCapacity(token);
    if (@TypeOf(token) == Token) if (seen) |observer| if (observer.punctuation or token.kind() == .word or token.kind() == .keyword or token.kind() == .string or token.kind() == .literal) try observer.token(observer.context, out.items);
}

fn recoverShaped(arena: std.mem.Allocator, source: []const u8, ts: []const StoredToken, shape: liveness.Shape) error{ InvalidLiteral, OutOfMemory }!Facts {
    var out: std.ArrayList(Import) = .empty;
    // The token of each spec, which says whether only tests reach it.
    var where: std.ArrayList(u32) = .empty;
    var unsupported: std.ArrayList(Unsupported) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (shape.imports) |index| {
        const i: usize = index;
        const t = ts[i];
        if (i + 4 >= ts.len or !ts[i + 2].is("(") or ts[i + 3].kind() != .string or !ts[i + 4].is(")")) {
            try unsupported.append(arena, .{ .offset = t.offset, .expression = .zig_import });
            continue;
        }
        // Without an escape or a line break a literal is its own value.
        const plain = std.mem.findAny(u8, ts[i + 3].text(), "\\\n") == null;
        const name = if (plain) ts[i + 3].text() else try std.zig.string_literal.parseAlloc(arena, source[ts[i + 3].offset..ts[i + 3].end()]);
        try out.append(arena, .{ .name = name, .offset = t.offset });
        try where.append(arena, index);
        if (i + 6 < ts.len and ts[i + 5].is(".") and ts[i + 6].kind() == .word) {
            try out.append(arena, .{ .name = name, .member = ts[i + 6].text(), .offset = t.offset });
            try where.append(arena, index);
        }
        // const/var alias [: type] = @import(...); as used by layering checks.
        // The `;` comes first: it bounds the walk back to the declaration.
        if (i > 0 and ts[i - 1].is("=") and i + 5 < ts.len and ts[i + 5].is(";")) {
            var j = i - 1;
            while (j > 0 and !ts[j - 1].is(";") and !ts[j - 1].is("{") and !ts[j - 1].is("}")) : (j -= 1) {}
            if (j + 1 < i and (ts[j].is("const") or ts[j].is("var")) and ts[j + 1].kind() == .word)
                try aliases.put(arena, ts[j + 1].text(), name);
        }
    }
    // Short streams have at most a handful of declarations. Specialising
    // the temporary table keeps its mask constant in the word loop.
    if (out.items.len > 0) {
        if (ts.len <= 128) try classify(64, arena, ts, shape, &out, &where, aliases) else try classify(256, arena, ts, shape, &out, &where, aliases);
    }
    const tests = try arena.alloc(Range, shape.tests.len);
    for (shape.tests, tests) |r, *bytes| bytes.* = .{ .first = ts[r.first].offset, .last = if (r.last + 1 < ts.len) ts[r.last + 1].offset - 1 else @intCast(source.len -| 1) }; // safe: checked byte bounds fit u32; byte ranges end before the following token.
    return .{ .tokens = &.{}, .imports = try out.toOwnedSlice(arena), .unsupported = try unsupported.toOwnedSlice(arena), .tests = tests };
}

fn classify(comptime capacity: usize, arena: std.mem.Allocator, ts: []const StoredToken, shape: liveness.Shape, out: *std.ArrayList(Import), where: *std.ArrayList(u32), aliases: std.StringHashMapUnmanaged([]const u8)) std.mem.Allocator.Error!void {
    // No recovered reference borrows this table after classification.
    var slots: [capacity]u32 = undefined;
    // A short stream has at most 128 members and references. Its member
    // lists, name links and grouped traversal fit in this bounded workspace.
    // One allocator owns all of that temporary state until classification.
    var buffer: [if (capacity == 64) 24 * 1024 else 0]u8 = undefined;
    var scratch: std.heap.FixedBufferAllocator = .init(&buffer);
    const workspace = if (capacity == 64) scratch.allocator() else arena;
    var words = try liveness.Words.init(workspace, ts, shape, &slots);
    var alias_lengths: u64 = 0;
    var alias_names = aliases.keyIterator();
    while (alias_names.next()) |name| alias_lengths |= @as(u64, 1) << @intCast(@min(name.len, 63)); // safe: bounded shift is at most 63.
    for (ts, 0..) |t, i| {
        if (t.kind() == .string) try words.see(capacity, i);
        if (t.kind() != .word) continue;
        try words.see(capacity, i);
        if (alias_lengths & (@as(u64, 1) << @intCast(@min(t.text().len, 63))) == 0) continue; // safe: bounded shift is at most 63.
        if (i + 2 >= ts.len or !dot(ts[i + 1]) or ts[i + 2].kind() != .word) continue;
        if (i > 0 and dot(ts[i - 1])) continue;
        if (aliases.get(t.text())) |name| {
            try out.append(arena, .{ .name = name, .member = ts[i + 2].text(), .offset = t.offset });
            try where.append(arena, @intCast(i)); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
        }
    }
    try words.classify(workspace, out.items, where.items);
}

inline fn dot(t: StoredToken) bool {
    return t.tag == .period;
}

inline fn initToken(comptime Element: type, tag: std.zig.Token.Tag, k: Element.Kind, text: []const u8, start: usize, finish: usize) Element {
    if (Element != Token) return Element.init(tag, text, start, finish);
    return .{ .text = text, .offset = @intCast(start), .detail = .{ .kind = k, .value = @intCast(finish - start) } }; // safe: checked source spans fit the packed u29 length and u32 offset.
}
