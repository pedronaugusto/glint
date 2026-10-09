//! Which Zig imports only a test build sees. Zig analyses lazily: code in a
//! `test` declaration, in the taken branch of `if (builtin.is_test)`, or in a
//! container-level declaration that nothing but tests reaches is never
//! compiled outside `zig test`. Read in the passes recovery already makes:
//! `Builder` as tokens are emitted, `Words.see` in its pass over words.
const std = @import("std");
const types = @import("data.zig");
const Token = @import("store.zig").Token;

/// Token indices, both ends included.
pub const Range = struct { first: u32, last: u32 };
/// Bracket partners borrow private token storage until recovery returns.
const Partners = struct {
    stream: []const Token,
    fn get(self: Partners, i: usize) u32 {
        return self.stream[i].partner();
    }
};

/// What one pass over a file's tokens finds for recovery and liveness.
pub const Shape = struct {
    /// Each `@` that starts an `@import`.
    imports: []const u32,
    /// For each bracket its partner; an unclosed one runs to the last token
    /// and a stray closer is its own partner. Other tokens are left undefined.
    partner: Partners,
    /// Disjoint and in order: `test` bodies at any depth, and the
    /// then-branches of `if (builtin.is_test)`, `if (comptime
    /// builtin.is_test)` and `if (@import("builtin").is_test)`, where
    /// `builtin` is any container-level `const` bound to `@import("builtin")`.
    tests: []const Range,
};

/// Bracket pairs and import/test marks collected as the lexer emits tokens.
/// Partners live in private token storage; public observer spans remain unchanged.
pub fn Builder(comptime small: bool) type {
    return struct {
        const Self = @This();
        const Tokens = []Token;
        open: SmallList(u32, if (small) 16 else 64) = .{},
        imports: SmallList(u32, if (small) 8 else 64) = .{},
        marks: SmallList(u32, if (small) 8 else 64) = .{},
        builtins: SmallList([]const u8, 4) = .{},

        pub inline fn token(self: *Self, arena: std.mem.Allocator, t: Token, ts: Tokens) std.mem.Allocator.Error!void {
            const i = ts.len - 1;
            switch (t.tag) {
                .l_paren, .l_bracket, .l_brace => try self.open.append(arena, @intCast(i)), // safe: source-bounded token index fits u32.
                .r_paren, .r_bracket, .r_brace => {
                    const o = self.open.pop() orelse @as(u32, @intCast(i)); // safe: source-bounded token index fits u32.
                    self.put(ts, o, @intCast(i)); // safe: source-bounded token index fits u32.
                    self.put(ts, i, o);
                },
                .keyword_test, .identifier => try self.marks.append(arena, @intCast(i)), // safe: emission supplies only test declarations and is_test identifiers here.
                else => {},
            }
            // Emission cannot look ahead to `import` or its literal operand.
            // Recognise the completed builtin binding at its closing parenthesis.
            if (t.is(")") and self.open.items().len == 0 and i >= 7 and ts[i - 7].is("const") and ts[i - 6].kind() == .word and ts[i - 5].is("=") and ts[i - 3].is("import") and builtinImport(ts, i - 4))
                try self.builtins.append(arena, ts[i - 6].text());
        }
        pub fn imported(self: *Self, arena: std.mem.Allocator, i: usize) std.mem.Allocator.Error!void {
            try self.imports.append(arena, @intCast(i)); // safe: source-bounded compact token index fits u32.
        }
        pub fn finish(self: *Self, arena: std.mem.Allocator, ts: Tokens) std.mem.Allocator.Error!Shape {
            // The `import` word completed each recorded prefix during emission.
            const n = self.imports.items().len;
            for (self.open.items()) |o| self.put(ts, o, @intCast(ts.len - 1)); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
            const partner: Partners = .{ .stream = ts };
            // Marks are in order and each range starts at or after its mark, so
            // the ranges come in order of their first token.
            var tests: std.ArrayList(Range) = .empty;
            for (self.marks.items()) |i| {
                const range: Range = if (testDecl(ts, i)) |brace| .{ .first = i, .last = partner.get(brace) } else if (isTestCondition(ts, i, self.builtins.items())) then: {
                    const first = i + 2;
                    if (first >= ts.len) continue;
                    const last = if (ts[first].is("{")) partner.get(first) else expressionEnd(ts, partner, first) orelse continue;
                    break :then .{ .first = first, .last = @intCast(last) }; // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
                } else continue;
                if (tests.items.len > 0 and range.first <= tests.items[tests.items.len - 1].last) {
                    const top = &tests.items[tests.items.len - 1];
                    top.last = @max(top.last, range.last);
                } else try tests.append(arena, range);
            }
            return .{ .imports = self.imports.items()[0..n], .partner = partner, .tests = tests.items };
        }
        fn put(self: *Self, ts: Tokens, i: usize, value: u32) void {
            _ = self;
            ts[i].setPartner(value);
        }
    };
}
/// Structural lists normally stay beside the builder. Spilling copies
/// their prefix once, then keeps one allocator-owned list, even after pop.
/// This keeps temporary marks from blocking token-buffer arena resizing.
fn SmallList(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [capacity]T = undefined,
        used: usize = 0,
        spill: std.ArrayList(T) = .empty,
        spilled: bool = false,

        fn items(self: *Self) []T {
            return if (self.spilled) self.spill.items else self.buffer[0..self.used];
        }
        fn append(self: *Self, arena: std.mem.Allocator, value: T) std.mem.Allocator.Error!void {
            if (!self.spilled and self.used == capacity) {
                try self.spill.appendSlice(arena, &self.buffer);
                self.spilled = true;
            }
            if (self.spilled) return self.spill.append(arena, value);
            self.buffer[self.used] = value;
            self.used += 1;
        }
        fn pop(self: *Self) ?T {
            if (self.spilled) return self.spill.pop();
            if (self.used == 0) return null;
            self.used -= 1;
            return self.buffer[self.used];
        }
    };
}
fn opener(t: Token) bool {
    return switch (t.tag) {
        .l_paren, .l_bracket, .l_brace => true,
        else => false,
    };
}
fn closer(t: Token) bool {
    return switch (t.tag) {
        .r_paren, .r_bracket, .r_brace => true,
        else => false,
    };
}

/// The body brace of a `test` declaration starting at `i`: `test {`,
/// `test "name" {` or `test name {`.
fn testDecl(ts: []const Token, i: usize) ?usize {
    if (!ts[i].is("test") or i + 1 >= ts.len) return null;
    if (ts[i + 1].is("{")) return i + 1;
    if ((ts[i + 1].kind() == .string or ts[i + 1].kind() == .word) and i + 2 < ts.len and ts[i + 2].is("{")) return i + 2;
    return null;
}

/// `@import("builtin")` from the `@` at `i`.
fn builtinImport(ts: []const Token, i: usize) bool {
    return i + 4 < ts.len and ts[i + 2].is("(") and ts[i + 3].kind() == .string and std.mem.eql(u8, ts[i + 3].text(), "builtin") and ts[i + 4].is(")");
}
/// `is_test` at `i` closes `if (B.is_test)` or `if (comptime B.is_test)`,
/// where `B` is `@import("builtin")` or one of `builtins`, the names bound
/// to it. Another value's `is_test` is no evidence of a test build.
fn isTestCondition(ts: []const Token, i: usize, builtins: []const []const u8) bool {
    if (!ts[i].is("is_test") or i < 3 or i + 1 >= ts.len or !ts[i + 1].is(")") or !ts[i - 1].is(".")) return false;
    var k = i - 2;
    if (ts[k].kind() == .word) {
        for (builtins) |name| {
            if (std.mem.eql(u8, name, ts[k].text())) break;
        } else return false;
        if (k == 0) return false;
        k -= 1;
    } else if (k >= 4 and ts[k].is(")") and builtinImport(ts, k - 4)) {
        if (k < 5) return false;
        k -= 5;
    } else return false;
    if (ts[k].is("comptime")) {
        if (k == 0) return false;
        k -= 1;
    }
    return k > 0 and ts[k].is("(") and ts[k - 1].is("if");
}
/// The last token of an expression starting at `first`: before the `else`,
/// `;`, `,` or closer that ends it at its own depth.
fn expressionEnd(ts: []const Token, partner: Partners, first: usize) ?usize {
    var k = first;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is("else") or t.is(";") or t.is(",") or closer(t)) break;
        k = if (opener(t)) partner.get(k) + 1 else k + 1;
    }
    return if (k > first) k - 1 else null;
}

pub const Member = struct { first: u32, last: u32, name: ?[]const u8 = null, root: bool = false, is_test: bool = false, this: bool = false };

/// The file's container-level members in order, tiling the stream.
fn rootMembers(arena: std.mem.Allocator, ts: []const Token, partner: Partners) ![]const Member {
    var out: std.ArrayList(Member) = .empty;
    var i: usize = 0;
    while (i < ts.len) {
        const m = memberFrom(ts, partner, i);
        try out.append(arena, m);
        i = m.last + 1;
    }
    return out.items;
}
fn memberFrom(ts: []const Token, partner: Partners, first: usize) Member {
    var m: Member = .{ .first = @intCast(first), .last = @intCast(first) }; // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
    var k = first;
    while (k < ts.len) : (k += 1) {
        const t = ts[k];
        if (t.is("pub") or t.is("export")) {
            m.root = true;
        } else if (t.is("comptime")) {
            m.root = true;
            if (k + 1 < ts.len and ts[k + 1].is("{")) return ending(m, partner.get(k + 1));
        } else if (t.is("extern")) {
            if (k + 1 < ts.len and ts[k + 1].kind() == .string) k += 1;
        } else if (!(t.is("inline") or t.is("noinline") or t.is("threadlocal"))) break;
    }
    if (k >= ts.len) return ending(m, ts.len - 1);
    if (testDecl(ts, k)) |brace| {
        m.is_test = true;
        return ending(m, partner.get(brace));
    }
    const t = ts[k];
    if (t.is("fn") or t.is("const") or t.is("var")) {
        if (k + 1 < ts.len and ts[k + 1].kind() == .word) m.name = ts[k + 1].text();
        if (m.name) |name| if (std.mem.eql(u8, name, "main")) {
            m.root = true;
        };
        m.this = k + 6 < ts.len and ts[k + 2].is("=") and ts[k + 3].is("@") and ts[k + 4].is("This") and ts[k + 5].is("(") and ts[k + 6].is(")");
        return ending(m, declarationEnd(ts, partner, k, t.is("fn")));
    }
    // A field, `usingnamespace` or bytes that are no declaration.
    m.root = true;
    return ending(m, fieldEnd(ts, partner, k));
}
fn ending(m: Member, end: usize) Member {
    var out = m;
    out.last = @intCast(@max(end, m.first)); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
    return out;
}
/// The `;` that ends a declaration, or a function's body brace.
fn declarationEnd(ts: []const Token, partner: Partners, start: usize, function: bool) usize {
    var k = start;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is(";")) return k;
        if (closer(t)) return k -| 1;
        if (function and t.is("{") and body(ts, partner, k)) return partner.get(k);
        k = if (opener(t)) partner.get(k) + 1 else k + 1;
    }
    return ts.len - 1;
}
/// A brace after a signature opens the body unless it opens a type in the
/// return type: `error{`, `struct {`, `union(enum) {`.
fn body(ts: []const Token, partner: Partners, k: usize) bool {
    if (k == 0) return true;
    const prev = ts[k - 1];
    if (prev.is(")")) {
        const o = partner.get(k - 1);
        return o == 0 or !container(ts[o - 1]);
    }
    return !prev.is("error") and !container(prev);
}
fn container(t: Token) bool {
    return t.is("struct") or t.is("union") or t.is("enum") or t.is("opaque");
}
fn fieldEnd(ts: []const Token, partner: Partners, start: usize) usize {
    var k = start;
    while (k < ts.len) {
        const t = ts[k];
        if (t.is(";") or t.is(",")) return k;
        if (closer(t)) return k -| 1;
        k = if (opener(t)) partner.get(k) + 1 else k + 1;
    }
    return ts.len - 1;
}

const Reach = enum { dead, live, test_only };

/// The names of container-level members that are not roots, the only ones
/// a reference can change: by their lengths, then by a slot of length and
/// ends with the members that share it chained. Most words name no such
/// member, and most of those are passed over without reading their bytes.
const Names = struct {
    const none = std.math.maxInt(u32);
    members: []const Member,
    /// The names bound to `@This()`, roots or not.
    this: []const []const u8,
    /// Bit `n` for a name of `n` bytes, the last bit for any longer.
    lengths: u64 = 0,
    counts: [64]u32 = @splat(0),
    slots: []u32,
    next: []u32,

    fn init(arena: std.mem.Allocator, members: []const Member, slots: []u32) std.mem.Allocator.Error!Names {
        @memset(slots, none);
        var this: std.ArrayList([]const u8) = .empty;
        var names: Names = .{ .members = members, .this = &.{}, .slots = slots, .next = try arena.alloc(u32, members.len) };
        for (members, 0..) |m, i| if (m.name) |name| {
            if (m.this) try this.append(arena, name);
            if (m.root) continue;
            names.lengths |= length(name);
            names.counts[@min(name.len, 63)] += 1;
            const slot = &slots[sketch(name) & (slots.len - 1)];
            names.next[i] = slot.*;
            slot.* = @intCast(i); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
        };
        names.this = this.items;
        return names;
    }
    inline fn find(self: *const Names, comptime capacity: usize, word: []const u8) ?u32 {
        if (self.lengths & length(word) == 0) return null;
        var i = self.slots[sketch(word) & (capacity - 1)];
        while (i != none) : (i = self.next[i]) if (std.mem.eql(u8, self.members[i].name.?, word)) return i;
        return null;
    }
    fn forget(self: *Names, target: u32) void {
        const name = self.members[target].name.?;
        const bucket = @min(name.len, 63);
        self.counts[bucket] -= 1;
        if (self.counts[bucket] == 0) self.lengths &= ~length(name);
        var link = &self.slots[sketch(name) & (self.slots.len - 1)];
        while (link.* != none) {
            if (link.* == target) {
                link.* = self.next[target];
                return;
            }
            link = &self.next[link.*];
        }
        unreachable;
    }
    fn length(word: []const u8) u64 {
        return @as(u64, 1) << @intCast(@min(word.len, 63)); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
    }
    fn sketch(word: []const u8) u12 {
        if (word.len == 0) return 0;
        return @truncate(word.len *% 1031 +% @as(usize, word[0]) *% 37 +% word[word.len - 1]); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
    }
};

/// References between container-level members, gathered as recovery walks
/// a file's words and strings. Live from the roots (`pub`, `export`,
/// `comptime`, fields, `main`), else test-only from `test` declarations and
/// references in test context, else dead. References are names outside
/// field position, `x.name(` calls, `Self.name` where `Self` is `@This()`,
/// decl and enum literals (`.name` that follows no operand and initialises
/// no field) and `@field(Self, "name")`: Zig forbids a local that shadows a
/// container-level name, so a matching name is that declaration. A doubtful
/// case is a reference, so it errs towards live.
pub const Words = struct {
    const Ref = struct { from: u32, to: u32 };
    arena: std.mem.Allocator,
    ts: []const Token,
    tests: []const Range,
    members: []const Member,
    names: Names,
    refs: std.ArrayList(Ref) = .empty,
    seeds: std.ArrayList(u32) = .empty,
    /// The member that last named each target: members come in order, so
    /// a repeat from the same member is dropped.
    named_by: []u32,
    seeded: []bool,
    live: []bool,
    /// The member and test range at or after the last word seen.
    at: usize = 0,
    in: usize = 0,

    pub fn init(arena: std.mem.Allocator, ts: []const Token, shape: Shape, slots: []u32) std.mem.Allocator.Error!Words {
        const members = try rootMembers(arena, ts, shape.partner);
        var result = try initMembers(arena, members, slots);
        result.ts = ts;
        result.tests = shape.tests;
        return result;
    }
    pub fn initMembers(arena: std.mem.Allocator, members: []const Member, slots: []u32) std.mem.Allocator.Error!Words {
        const named_by = try arena.alloc(u32, members.len);
        @memset(named_by, Names.none);
        const seeded = try arena.alloc(bool, members.len);
        @memset(seeded, false);
        const live = try arena.alloc(bool, members.len);
        for (members, live) |member, *value| value.* = member.root;
        return .{ .arena = arena, .ts = &.{}, .tests = &.{}, .members = members, .names = try .init(arena, members, slots), .named_by = named_by, .seeded = seeded, .live = live };
    }
    /// Each word and string of the stream, in order.
    pub inline fn see(self: *Words, comptime capacity: usize, i: usize) std.mem.Allocator.Error!void {
        const target = self.names.find(capacity, self.ts[i].text()) orelse return;
        if (self.live[target]) return;
        if (!reference(self.ts, i, &self.names)) return;
        while (self.members[self.at].last < i) self.at += 1;
        while (self.in < self.tests.len and self.tests[self.in].last < i) self.in += 1;
        if (self.in < self.tests.len and self.tests[self.in].first <= i) {
            if (!self.seeded[target]) try self.seeds.append(self.arena, target);
            self.seeded[target] = true;
        } else if (self.live[self.at]) {
            self.live[target] = true;
            self.names.forget(target);
        } else if (self.at != target and self.named_by[target] != self.at) {
            self.named_by[target] = @intCast(self.at); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
            try self.refs.append(self.arena, .{ .from = @intCast(self.at), .to = target }); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
        }
    }
    /// After every word: marks `test` each spec whose token only a test
    /// build analyses, and `dead` each one no build analyses. A dead import
    /// keeps its kind, since dead code is no evidence of a test. `where`
    /// holds the index in the stream of each spec's token.
    pub fn classify(self: *Words, scratch: std.mem.Allocator, specs: []types.Import, where: []const u32) std.mem.Allocator.Error!void {
        std.debug.assert(specs.len == where.len);
        const reach = try self.reachable(scratch);
        var member: usize = 0;
        var test_range: usize = 0;
        var previous: u32 = 0;
        for (specs, where) |*spec, at| {
            // Base-import and alias-member facts each arrive in token order.
            if (at < previous) {
                member = 0;
                test_range = 0;
            }
            previous = at;
            while (self.members[member].last < at) member += 1;
            while (test_range < self.tests.len and self.tests[test_range].last < at) test_range += 1;
            const state = reach[member];
            spec.dead = state == .dead;
            const in_test = test_range < self.tests.len and self.tests[test_range].first <= at;
            if (spec.kind == .import and (in_test or state == .test_only)) spec.kind = .@"test";
        }
    }

    pub fn reachable(self: *Words, arena: std.mem.Allocator) ![]const Reach {
        const n = self.members.len;
        if (self.refs.items.len == 0) {
            const out = try arena.alloc(Reach, n);
            for (self.members, self.live, out) |m, is_live, *state| state.* = if (is_live) .live else if (m.is_test) .test_only else .dead;
            for (self.seeds.items) |target| if (out[target] == .dead) {
                out[target] = .test_only;
            };
            return out;
        }
        // Edges grouped by source for the walk.
        const starts = try arena.alloc(u32, n + 1);
        @memset(starts, 0);
        for (self.refs.items) |r| starts[r.from + 1] += 1;
        for (1..starts.len) |i| starts[i] += starts[i - 1];
        const targets = try arena.alloc(u32, self.refs.items.len);
        const fill = try arena.dupe(u32, starts[0..n]);
        for (self.refs.items) |r| {
            targets[fill[r.from]] = r.to;
            fill[r.from] += 1;
        }
        const out = try arena.alloc(Reach, n);
        @memset(out, .dead);
        var stack: std.ArrayList(u32) = .empty;
        for ([_]Reach{ .live, .test_only }) |mark| {
            for (self.members, 0..) |m, i| if (if (mark == .live) self.live[i] else m.is_test) try stack.append(arena, @intCast(i)); // safe: source length is bounded below half u32; token/member tables fit u32, and sketches intentionally keep their low bits.
            if (mark == .test_only) try stack.appendSlice(arena, self.seeds.items);
            while (stack.pop()) |i| {
                if (out[i] != .dead) continue;
                out[i] = mark;
                for (targets[starts[i]..starts[i + 1]]) |j| if (out[j] == .dead) try stack.append(arena, j);
            }
        }
        return out;
    }
};
fn reference(ts: []const Token, i: usize, names: *const Names) bool {
    if (ts[i].kind() == .string) return i >= 2 and ts[i - 1].is(",") and i + 1 < ts.len and ts[i + 1].is(")") and fieldOfThis(ts, i - 2, names);
    const next_colon = i + 1 < ts.len and ts[i + 1].is(":");
    if (i == 0) return !next_colon;
    const prev = ts[i - 1];
    // `.name` after an operand is a member of something else unless called,
    // or of `@This()`; `..name` is a range bound.
    if (prev.is(".") and !(i >= 2 and ts[i - 2].is("."))) {
        if (i + 1 < ts.len and ts[i + 1].is("(")) return true;
        if (i < 2) return true;
        if (operand(ts, i - 2)) return containerThis(ts, i - 2, names);
        // A decl or enum literal, unless it names a field it initialises:
        // `.{ .name = x }`.
        const field = (ts[i - 2].is("{") or ts[i - 2].is(",")) and i + 2 < ts.len and ts[i + 1].is("=") and !(ts[i + 2].is("=") or ts[i + 2].is(">"));
        return !field;
    }
    // The label of `break :name` or `continue :name`.
    if (prev.is(":") and i >= 2 and (ts[i - 2].is("break") or ts[i - 2].is("continue"))) return false;
    // A field, parameter or label name, but not a sentinel `[n:0]` or `[a..n :0]`.
    return !next_colon or prev.is("[") or prev.is(".");
}

/// Whether the expression ending at `k` is `@This()` or a name bound to it.
fn containerThis(ts: []const Token, k: usize, names: *const Names) bool {
    const owner = ts[k];
    if (owner.kind() == .word) {
        for (names.this) |name| if (std.mem.eql(u8, name, owner.text())) return true;
        return false;
    }
    return owner.is(")") and k >= 3 and ts[k - 1].is("(") and ts[k - 2].is("This") and ts[k - 3].is("@");
}
/// `@field(T, ` before the `,` that follows `k`, with `T` the container.
fn fieldOfThis(ts: []const Token, k: usize, names: *const Names) bool {
    if (!containerThis(ts, k, names)) return false;
    const open = if (ts[k].kind() == .word) k -| 1 else k -| 4;
    return open >= 2 and ts[open].is("(") and (ts[open - 1].is("field") or ts[open - 1].is("hasDecl")) and ts[open - 2].is("@");
}
/// Whether token `k` ends an operand, so a `.name` after it is a member:
/// a name that is no keyword (`error` is one), a literal, a closer, or the
/// `?` and `*` of `x.?` and `x.*`. A label (`break :blk .x`) is none.
fn operand(ts: []const Token, k: usize) bool {
    const t = ts[k];
    return switch (t.kind()) {
        .word => !(k >= 2 and ts[k - 1].is(":") and (ts[k - 2].is("break") or ts[k - 2].is("continue"))),
        .string, .literal => true,
        .keyword => t.is("error"),
        .punctuation => closer(t) or ((t.is("?") or t.is("*")) and k >= 1 and ts[k - 1].is(".")),
    };
}
