// The module the case's hole imports as "missing": given to the compiler, never to glint, so
// glint reads a module it is not given (its mapping absent).
pub fn free(p: *[4]u8) void {
    _ = p;
}
