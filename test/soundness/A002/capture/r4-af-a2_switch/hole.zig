// review 4: af/a2_switch.zig
const S = @import("aegis").Secret;
const H = struct { s: S(u32), t: S(u32) };
pub fn f(h: *H, k: u8) void {
    var copy = switch (k) {
        0 => h.s,
        else => h.t,
    };
    copy.deinit();
}
