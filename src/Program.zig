//! The files that are the program: every loaded file but std's and aegis's, which the analyses
//! know by their declarations. A file of the package the run did not select and a dependency's
//! are the program's as much as a selected one: what they do runs as its own, so an analysis
//! that reads the program reads them too, and one that stops at a selection decides nothing
//! past it.
const std = @import("std");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Project = @import("Project.zig");

/// The files std's import reaches, and aegis's.
std_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
aegis_files: std.AutoHashMapUnmanaged(u32, void) = .empty,
built: bool = false,

const Program = @This();

/// The run's program, found the first time an analysis asks.
pub fn get(c: *Context) Context.Error!*const Program {
    const program = try c.facts.memo(Program);
    if (program.built) return program;
    program.built = true;
    for (c.project.imports) |mapping| if (std.mem.eql(u8, mapping.spelling, "std")) try reach(c, &program.std_files, mapping.target);
    const aegis = try c.facts.publication(Contract.library);
    for (aegis.files) |file| try program.aegis_files.put(c.allocator, @backingInt(file), {});
    return program;
}

/// Whether `file` is the program's.
pub fn own(program: *const Program, file: Project.FileId) bool {
    return !program.std_files.contains(@backingInt(file)) and !program.aegis_files.contains(@backingInt(file));
}

/// Whether `file` is the program's, found through the run's program.
pub fn owns(c: *Context, file: Project.FileId) Context.Error!bool {
    return (try get(c)).own(file);
}

/// Every file `root` reaches through its own imports.
fn reach(c: *Context, set: *std.AutoHashMapUnmanaged(u32, void), root: Project.FileId) Context.Error!void {
    if ((try set.getOrPut(c.allocator, @backingInt(root))).found_existing) return;
    var stack: std.ArrayList(Project.FileId) = .empty;
    try stack.append(c.allocator, root);
    while (stack.pop()) |file| for (c.project.imports) |mapping| {
        if (mapping.from != file) continue;
        if ((try set.getOrPut(c.allocator, @backingInt(mapping.target))).found_existing) continue;
        try stack.append(c.allocator, mapping.target);
    };
}
