//! Public token facts and borrowed observer records.
const std = @import("std");
pub const Token = struct {
    text: []const u8,
    offset: u32,
    detail: packed struct(u32) { kind: Kind, value: u29 },
    pub const Kind = enum(u3) { word, string, punctuation, keyword, literal };
    pub inline fn kind(t: Token) Kind {
        return t.detail.kind;
    }
    pub inline fn end(t: Token) u32 {
        return t.offset + t.detail.value; // safe: checked source spans fit u32.
    }
    pub inline fn is(t: Token, spelling: []const u8) bool {
        return (t.kind() == .word or t.kind() == .keyword or t.kind() == .punctuation) and std.mem.eql(u8, t.text, spelling);
    }
};
pub const Observer = struct {
    context: *anyopaque,
    punctuation: bool = false,
    boundary: ?*const fn (*anyopaque) void = null,
    token: *const fn (*anyopaque, Token) error{OutOfMemory}!void,
};
pub const Import = struct {
    name: []const u8,
    member: ?[]const u8 = null,
    offset: usize,
    kind: enum { import, @"test" } = .import,
    dead: bool = false,
};
pub const Unsupported = struct { offset: usize, expression: enum { zig_import } = .zig_import };
/// Inclusive source byte offsets.
pub const Range = struct { first: u32, last: u32 };
pub const Facts = struct { imports: []const Import, unsupported: []const Unsupported, tests: []const Range };
pub const Error = error{ InvalidLiteral, SourceTooLarge, OutOfMemory };
