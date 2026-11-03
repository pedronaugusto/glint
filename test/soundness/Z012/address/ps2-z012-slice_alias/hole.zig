const Hidden = struct { x: u8 };
/// A public name for a slice of a type callers cannot name.
pub const Many = []const Hidden;
