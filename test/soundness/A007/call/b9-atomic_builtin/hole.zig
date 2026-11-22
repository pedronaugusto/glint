// A007: a raw atomic access by builtin, no cell named: a finding.
const aegis = @import("aegis");
pub fn read(p: *const u32) u32 {
    return @atomicLoad(u32, p, .acquire);
}
