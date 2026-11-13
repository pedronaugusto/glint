// Z012: a public type function's struct, on the public surface, holds a private type in a field.
const Marks = struct { count: u8 };
pub fn Out(comptime width: u8) type {
    return struct {
        marks: *const Marks,
        pub const size = width;
    };
}
