// replaces .decl: a reference by another name is the declaration's: the alias is the finding,
// and so is the function taken as a value, never called here.
const std = @import("std");
const sync = std.Io.File.sync;

pub fn f() *const @TypeOf(sync) {
    return &sync;
}
