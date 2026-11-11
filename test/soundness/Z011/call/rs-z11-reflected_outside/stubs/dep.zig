pub fn first(comptime T: type) *const fn () void {
    return &@field(T, @typeInfo(T).@"struct".decl_names[0]);
}
