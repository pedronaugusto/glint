// P008, hygiene: two ids of a type parameter, which resolves to no type here, are not shown to
// be one integer, and are silent (8c): a type that does not resolve is no report.
pub fn Link(comptime T: type) type {
    return struct {
        pub fn link(parent_id: T, child_id: T) void {
            _ = parent_id;
            _ = child_id;
        }
    };
}
