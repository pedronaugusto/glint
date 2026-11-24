// P007: an element of an inline prong's capture over a union std-style code builds with
// @Union from its operations' Result types: a tuple's element, no pointer (reactor's timeout).
const A = struct {
    pub const Result = struct { ?anyerror, usize };
};
const B = struct {
    pub const Result = struct { ?anyerror, usize };
};
const Op = union(enum) { a: A, b: B };
const Tag = @typeInfo(Op).@"union".tag_type.?;
pub const Result = Result: {
    const info = @typeInfo(Op).@"union";
    var field_names: [info.field_names.len][]const u8 = undefined;
    var field_types: [info.field_names.len]type = undefined;
    for (info.field_names, info.field_types, &field_names, &field_types) |n, t, *name, *ty| {
        name.* = n;
        ty.* = t.Result;
    }
    break :Result @Union(.auto, Tag, &field_names, &field_types, &@splat(.{}));
};
pub fn f(result: Result) usize {
    switch (result) {
        inline .a, .b => |moved| return moved[1],
    }
}
