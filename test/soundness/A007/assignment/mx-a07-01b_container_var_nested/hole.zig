// matrix A007: a container-level var in a struct a function declares is still mutable state any thread may reach.
const Phase = enum(u32) { idle, busy };
pub fn claim() Phase {
    const Shared = struct {
        var phase: Phase = .idle;
    };
    const was = Shared.phase;
    Shared.phase = .busy;
    return was;
}
