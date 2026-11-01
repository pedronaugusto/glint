// review 4: af/a2r_base.zig
const bounded = @import("aegis").bounded;
const R = bounded.Budget(u32).Reservation;
const Hold = struct { maybe: ?R, list: [2]R };
pub fn f(h: *Hold) void {
    var kept = h.list[0];
    kept.release();
}
