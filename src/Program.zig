//! The files that are the program: every loaded file but std's and aegis's, which the analyses
//! know by their declarations. A file of the package the run did not select and a dependency's
//! are the program's as much as a selected one: what they do runs as its own, so an analysis
//! that reads the program reads them too, and one that stops at a selection decides nothing
//! past it. Facts holds the one definition (`Facts.program`); this is its face for the rules.
const Context = @import("RuleContext.zig");
const Facts = @import("Facts.zig");
const Project = @import("Project.zig");

/// The files std's import reaches, and aegis's.
std_files: *const Facts.FileSet = &none,
aegis_files: *const Facts.FileSet = &none,
outside: ?*const Facts.Outside = null,

const Program = @This();
const none: Facts.FileSet = .empty;

/// The run's program, found the first time an analysis asks.
pub fn get(c: *Context) Context.Error!*const Program {
    const program = try c.facts.memo(Program);
    if (program.outside != null) return program;
    const outside = try c.facts.outside();
    program.* = .{ .std_files = &outside.std_files, .aegis_files = &outside.known_files, .outside = outside };
    return program;
}

/// Whether `file` is the program's.
pub fn own(program: *const Program, file: Project.FileId) bool {
    return program.outside.?.own(file);
}

/// Whether `file` is the program's, found through the run's program.
pub fn owns(c: *Context, file: Project.FileId) Context.Error!bool {
    return c.facts.program(file);
}
