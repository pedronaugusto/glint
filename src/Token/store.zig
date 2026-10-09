//! Private standard-token identities and decoded source slices.
const std = @import("std");
pub const Token = struct {
    ptr: [*]const u8,
    length: u32,
    offset: u32,
    tag: std.zig.Token.Tag,
    link: u32 = 0,
    pub const Kind = enum { word, string, punctuation, keyword, literal };
    pub inline fn kind(t: Token) Kind {
        return switch (t.tag) {
            .identifier => .word,
            .string_literal => .string,
            .number_literal => .literal,
            else => if (@backingInt(t.tag) >= @backingInt(std.zig.Token.Tag.keyword_addrspace)) .keyword else .punctuation, // safe: standard keyword tags form the final contiguous enum group.
        };
    }
    pub inline fn text(t: Token) []const u8 {
        return t.ptr[0..t.length];
    }
    pub inline fn partner(t: Token) u32 {
        return t.link;
    }
    pub inline fn setPartner(t: *Token, index: u32) void {
        t.link = index;
    }
    pub inline fn end(t: Token) u32 {
        return t.offset + switch (t.tag) {
            .l_paren, .r_paren, .l_bracket, .r_bracket, .l_brace, .r_brace => @as(u32, 1), // safe: one bracket byte fits u32.
            else => t.link,
        }; // safe: exact source spans fit checked source bounds; partners replace only bracket widths.
    }
    pub inline fn is(t: Token, comptime spelling: []const u8) bool {
        const tag = comptime spellingTag(spelling);
        return t.tag == tag and (tag != .identifier or std.mem.eql(u8, t.text(), spelling));
    }
    fn spellingTag(comptime spelling: []const u8) std.zig.Token.Tag {
        if (std.mem.eql(u8, spelling, "@")) return .builtin;
        var lexer = std.zig.Tokenizer.init(spelling ++ "\x00");
        return lexer.next().tag;
    }
    pub inline fn init(tag: std.zig.Token.Tag, bytes: []const u8, start: usize, finish: usize) Token {
        return .{ .ptr = bytes.ptr, .length = @intCast(bytes.len), .offset = @intCast(start), .link = @intCast(finish - start), .tag = tag }; // safe: checked source bounds limit tokenizer offsets below u32.
    }
    pub inline fn initEscaped(bytes: []const u8, start: usize, finish: usize) Token {
        return init(.identifier, bytes, start, finish);
    }
};
