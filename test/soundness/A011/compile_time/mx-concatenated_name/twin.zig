// matrix: aegis's Duration's member reached by @field with a name the compiler concatenates
const std = @import("std");
const aegis = @import("aegis");
const Ms = aegis.units.Duration(.millisecond, i32);
pub fn f(ms: Ms) std.Io.Duration {
    return @field(Ms, "toIo" ++ "Duration")(ms);
}
