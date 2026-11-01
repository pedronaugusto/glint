// review 5: b/b14g_inline_else_choice.zig
const std = @import("std");
const Small = struct {
    pub const n = 4;
};
const Large = struct {
    pub const n = 64;
};
const Kind = enum { small, large };
fn Type(comptime k: Kind) type {
    return switch (k) {
        .small => Small,
        .large => Large,
    };
}
pub fn f(r: *std.Io.Reader, k: Kind) !u64 {
    const x: u64 = try r.takeInt(u64, .little);
    switch (k) {
        inline else => |t| {
            if (x >= Type(t).n) return 0;
            return x * (1 << 59);
        },
    }
}
