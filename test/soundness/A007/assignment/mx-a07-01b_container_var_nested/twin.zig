// matrix A007: the same state held by aegis's Atomic.
const aegis = @import("aegis");
const Phase = enum(u32) { idle, busy };
pub fn claim() Phase {
    const Shared = struct {
        var phase: aegis.Atomic(Phase) = .init(.idle);
    };
    return Shared.phase.swap(.busy, .acq_rel);
}
