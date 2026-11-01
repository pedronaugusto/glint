// matrix A007: the same @as giving aegis's Atomic.
const aegis = @import("aegis");
const Phase = enum(u32) { idle, busy };
pub fn claim() Phase {
    var cell = @as(aegis.Atomic(Phase), .init(.idle));
    _ = cell.swap(.busy, .acq_rel);
    return cell.load(.acquire);
}
