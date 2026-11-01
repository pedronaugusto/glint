// matrix: Z013 call: a private binding of an import handed through a type function that returns it, used
fn Identity(comptime T: type) type {
    return T;
}
const extra = Identity(@import("extra.zig"));
pub const value = extra.value;
