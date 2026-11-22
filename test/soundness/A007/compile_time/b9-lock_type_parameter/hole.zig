// A007: a type function given std's lock, which its field holds apart from the data: a finding.
const aegis = @import("aegis");
const std = @import("std");
fn Locked(comptime Lock: type) type {
    return struct { lock: Lock = .init, count: u32 = 0 };
}
pub const Counter = Locked(std.Io.Mutex);
