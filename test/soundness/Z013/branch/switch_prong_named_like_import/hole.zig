// Z013: a dead import; a switch prong's tag spells its name
const extra = @import("extra.zig");
const Kind = enum { extra, plain };
pub fn code(k: Kind) u8 {
    return switch (k) {
        .extra => 1,
        .plain => 2,
    };
}
