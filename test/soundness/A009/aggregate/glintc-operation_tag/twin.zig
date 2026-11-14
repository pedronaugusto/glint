// A009: an operation's tag tested, by comparison or a switch's prongs: what a union holds is
// asked, no read is made (uplink's Timed and Socket choose a deadline by it, 8h).
const aegis = @import("aegis");
const std = @import("std");
pub fn reads(op: std.Io.Operation) bool {
    if (op == .net_read) return true;
    if ((op) != .file_read_streaming) return switch (op) {
        .net_receive => true,
        else => false,
    };
    return true;
}
