// matrix: aegis's conversion reached by @field with a name held in a constant
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
const door = "toIoDuration";
pub fn f(ms: Ms) std.Io.Duration {
    return @field(Ms, door)(ms);
}
