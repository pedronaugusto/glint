// matrix A007: @as gives a variable the cell a dependency's type function makes: std's atomic.Value.
const dep = @import("dep.zig");
pub fn bump() u32 {
    var hits = @as(dep.Cell(u32), .init(0));
    _ = hits.fetchAdd(1, .monotonic);
    return hits.load(.monotonic);
}
