// A result type a generic chooses by its parameter: Hidden for u8.
const Hidden = struct { x: u8 };
pub fn make(comptime T: type) if (T == u8) Hidden else T {
    return undefined;
}
