// Z005: a function declared to return `type`, named as a callable.
pub fn pick(comptime wide: bool) type {
    return if (wide) u64 else u32;
}
