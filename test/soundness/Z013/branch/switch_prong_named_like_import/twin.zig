// twin
const extra = @import("extra.zig");
const Kind = enum { extra, plain };
pub fn code(k: Kind) u8 {
    return switch (k) {
        .extra => extra.value,
        .plain => 2,
    };
}
