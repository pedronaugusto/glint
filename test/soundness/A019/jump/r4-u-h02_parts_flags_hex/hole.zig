// review 4: u/h02_parts_flags_hex.zig
// held? parts across jumps, hexToBytes with a wrong or misplaced length test (expected: one finding each)
const std = @import("std");
const S = struct { a: u32, b: u32 };
pub fn p1(c: bool) u32 {
    var s: S = undefined;
    blk: {
        s.a = 1;
        if (c) break :blk;
        s.b = 2;
    }
    return s.a + s.b;
}
pub fn p2(c: bool) u32 {
    var s: [2]u32 = undefined;
    for (0..1) |_| {
        s[0] = 1;
        if (c) continue;
        s[1] = 2;
    }
    return s[0] + s[1];
}
pub fn x1(in: []const u8) ![16]u8 {
    var out: [16]u8 = undefined;
    if (in.len != 64) return error.Bad;
    _ = try std.fmt.hexToBytes(&out, in);
    return out;
}
pub fn x2(in: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (in.len == 64) {} else {
        _ = try std.fmt.hexToBytes(&out, in);
        return out;
    }
    return error.Bad;
}
pub fn x3(in: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (in.len > 64) return error.Bad;
    _ = try std.fmt.hexToBytes(&out, in);
    return out;
}
pub fn x4(in: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    if (in.len != 64) return error.Bad;
    _ = std.fmt.hexToBytes(&out, in) catch {};
    return out;
}
