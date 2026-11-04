// A record holds a guarded value by value, and the guarded payload is a secret owed its
// release: a guarded value owes no release of its own, but what it carries does, and nothing
// releases it.
const aegis = @import("aegis");
const Held = struct { locked: aegis.Guarded(aegis.Secret([4]u8)), count: u32 };
fn make(key: [4]u8) Held {
    return .{ .locked = .init(.init(key)), .count = 0 };
}
pub fn f(key: [4]u8) u32 {
    var held = make(key);
    held.count += 1;
    return held.count;
}
