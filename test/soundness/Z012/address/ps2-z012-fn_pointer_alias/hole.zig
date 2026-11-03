const Hidden = struct { x: u8 };
/// Callers write functions of this type, whose parameter they cannot name.
pub const Callback = *const fn (Hidden) void;
