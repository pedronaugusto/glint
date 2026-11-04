// A record holds a guarded value and an atomic by value, carrying plain numbers: neither kind
// owes a release, and what they carry owes none.
const aegis = @import("aegis");
const Phase = enum(u8) { idle, busy };
const Held = struct { locked: aegis.Guarded(u32), phase: aegis.Atomic(Phase), count: u32 };
fn make() Held {
    return .{ .locked = .init(0), .phase = .init(.idle), .count = 0 };
}
pub fn f() u32 {
    var held = make();
    held.count += 1;
    return held.count;
}
