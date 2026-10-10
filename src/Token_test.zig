const std = @import("std");
const token = @import("glint").Token;

test "morning token literals aliases ranges named tests and conditional tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try token.scan(arena.allocator(),
        \\const builtin = @import("builtin");
        \\const dep = @import("dep.zig");
        \\const bound = @import("bound.zig");
        \\fn target() void { _ = @import("target.zig"); }
        \\test target {}
        \\pub fn run() void {
        \\    _ = dep.read;
        \\    _ = (0..bound);
        \\    if (builtin.is_test) { _ = @import("test.zig"); }
        \\    _ = "@import(\"fake\")";
        \\    // @import("comment.zig")
        \\}
    , null);
    try std.testing.expectEqual(@as(usize, 7), facts.imports.len); // safe: five import operands and two alias members.
    for (facts.imports) |imp| {
        if (std.mem.eql(u8, imp.name, "target.zig") or std.mem.eql(u8, imp.name, "test.zig")) try std.testing.expectEqual(.@"test", imp.kind);
        if (std.mem.eql(u8, imp.name, "bound.zig")) try std.testing.expect(!imp.dead);
        try std.testing.expect(!std.mem.eql(u8, imp.name, "fake"));
    }
}

test "morning token computed import is incomplete and escaped names decode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try token.scan(arena.allocator(), "pub const dep = @import(\"d\\x65p\").@\"read\"; pub const unknown = @import(name);", null);
    try std.testing.expectEqual(@as(usize, 2), facts.imports.len); // safe: base and direct member facts.
    try std.testing.expectEqualStrings("dep", facts.imports[0].name);
    try std.testing.expectEqualStrings("read", facts.imports[1].member.?);
    try std.testing.expectEqual(@as(usize, 1), facts.unsupported.len); // safe: one computed operand.
}

test "morning token reflection and decl literal keep lazy imports live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try token.scan(arena.allocator(), "const Self = @This(); fn selected() void { _ = @import(\"selected.zig\"); } fn reflected() void { _ = @import(\"reflected.zig\"); } pub fn run() void { _ = .selected; _ = @hasDecl(Self, \"reflected\"); }", null);
    for (facts.imports) |imp| try std.testing.expect(!imp.dead);
}

test "token observer sees exact escaped spans and range punctuation as the pass reaches them" {
    const Capture = struct {
        const Self = @This();
        calls: usize = 0,
        boundaries: usize = 0,
        dots: usize = 0,
        escaped: bool = false,
        bytes: []const u8,
        fn boundary(raw: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(raw)); // safe: observer context is this caller-owned Capture.
            self.boundaries += 1;
        }
        fn see(raw: *anyopaque, t: token.Token) error{OutOfMemory}!void {
            const self: *Self = @ptrCast(@alignCast(raw)); // safe: observer context is this caller-owned Capture.
            self.calls += 1;
            if (t.is(".")) self.dots += 1;
            std.debug.assert(t.offset < t.end());
            std.debug.assert(t.end() <= self.bytes.len);
            if (std.mem.eql(u8, t.text, "escaped name")) {
                self.escaped = true;
                std.debug.assert(std.mem.eql(u8, "@\"escaped\\x20name\"", self.bytes[t.offset..t.end()]));
            }
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = "const @\"escaped\\x20name\" = @import(\"dep\"); pub fn f() void { _ = 0..4; _ = 'x'; _ = a == b; }";
    var capture: Capture = .{ .bytes = bytes };
    const observed = try token.scan(arena.allocator(), bytes, .{ .context = &capture, .punctuation = true, .boundary = Capture.boundary, .token = Capture.see });
    try std.testing.expectEqual(@as(usize, 2), capture.dots); // safe: the range consists of two dot tokens.
    try std.testing.expectEqual(@as(usize, 1), capture.boundaries); // safe: one character literal interrupts policy observation.
    try std.testing.expect(capture.escaped);
    // Every punctuation byte of `==` arrives, and without punctuation none does.
    var plain: Capture = .{ .bytes = bytes };
    const quiet = try token.scan(arena.allocator(), bytes, .{ .context = &plain, .boundary = Capture.boundary, .token = Capture.see });
    try std.testing.expectEqual(@as(usize, 0), plain.dots); // safe: punctuation is not observed.
    try std.testing.expect(plain.calls < capture.calls);
    // Observing changes no fact.
    const unobserved = try token.scan(arena.allocator(), bytes, null);
    try std.testing.expectEqualDeep(unobserved, observed);
    try std.testing.expectEqualDeep(unobserved, quiet);
}

test "pointer dereference does not become a second range dot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try token.scan(arena.allocator(), "fn hidden() void { _ = @import(\"hidden\"); } pub fn f(v: anytype) void { _ = v.*.hidden; }", null);
    try std.testing.expectEqual(@as(usize, 1), facts.imports.len); // safe: one lazy import.
    try std.testing.expect(facts.imports[0].dead);
}

test "escaped builtin test member spelling keeps test-only imports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const facts = try token.scan(arena.allocator(), "pub fn f() void { if (@import(\"builtin\").@\"is_test\") { _ = @import(\"test-only\"); } }", null);
    try std.testing.expectEqual(@as(usize, 3), facts.imports.len); // safe: builtin base/member plus the guarded import.
    try std.testing.expectEqual(.@"test", facts.imports[2].kind);
}
