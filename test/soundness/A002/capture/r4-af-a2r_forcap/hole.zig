// review 4: af/a2r_forcap.zig
const bounded = @import("aegis").bounded;
const R = bounded.Budget(u32).Reservation;
const Hold = struct { maybe: ?R, list: [2]R };
pub fn f(h: *Hold) void {
    for (h.list) |r| {
        var kept = r;
        kept.release();
    }
    h.list[0].release();
}
