const std = @import("std");

/// The parameter count of each of a vtable's functions, read off its type information.
pub fn arity(comptime Table: type, comptime name: []const u8) usize {
    const info = @typeInfo(@typeInfo(@FieldType(Table, name)).pointer.child).@"fn";
    return info.param_types.len;
}

const VTable = struct { read: *const fn (u32, u8) void };

pub fn readArity() usize {
    return arity(VTable, "read");
}
