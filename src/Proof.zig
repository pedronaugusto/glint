//! Whether the check a safe build makes at a site holds on every path to it: by Range's facts
//! about each value (its type, the comparisons holding where it is read), or by Bounds'
//! relations among values along each path. The flow rules ask here; Range and Bounds each
//! answer alone, and Bounds reads Range's facts, never the other way.

const std = @import("std");
const Context = @import("RuleContext.zig");
const Project = @import("Project.zig");
const Range = @import("Range.zig");
const Bounds = @import("Bounds.zig");
const Ast = std.zig.Ast;

/// Arithmetic `node` within its type.
pub fn fits(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return try Range.fits(c, file, node) or try Bounds.cleared(c, file, node, .arith);
}

/// The conversion `node` of `operand` within its destination.
pub fn converts(c: *Context, file: Project.FileId, node: Ast.Node.Index, operand: Ast.Node.Index) Context.Error!bool {
    return try Range.converts(c, file, node, operand) or try Bounds.cleared(c, file, node, .cast);
}

/// A divisor other than zero.
pub fn nonzero(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return try Range.nonzero(c, file, node) or try Bounds.cleared(c, file, node, .divisor);
}

/// An index below its memory's length, or a slice's bound (`end`) at most it.
pub fn within(c: *Context, file: Project.FileId, index: Ast.Node.Index, memory: Ast.Node.Index, end: bool) Context.Error!bool {
    return try Range.within(c, file, index, memory, end) or try Bounds.within(c, file, index, memory, end);
}

/// A slice's start at most its end.
pub fn notAfter(c: *Context, file: Project.FileId, start: Ast.Node.Index, end: Ast.Node.Index, memory: Ast.Node.Index) Context.Error!bool {
    return try Range.notAfter(c, file, start, end, memory) or try Bounds.notAfter(c, file, start, end);
}

/// A loop's bound held to a short's count, or between zero and the length of memory the
/// function holds: a peer chooses no more passes than the work it already sent.
pub fn counts(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return try Range.small(c, file, node) or try Bounds.cleared(c, file, node, .count);
}

/// A loop's passes at most a short's count, or the length of memory the function holds that the
/// loop leaves alone, on every path to each pass: a peer chooses no more passes than the work it
/// already sent, whatever decides them.
pub fn passes(c: *Context, file: Project.FileId, loop: Ast.Node.Index) Context.Error!bool {
    return Bounds.cleared(c, file, loop, .passes);
}

/// A switch prong no path takes, by Bounds' reading of its subject on every path to it: its
/// items, or for an `else` every value outside the other prongs', never the subject's there.
pub fn untaken(c: *Context, file: Project.FileId, prong: Ast.Node.Index) Context.Error!bool {
    return Bounds.cleared(c, file, prong, .untaken);
}

/// A `.?` whose operand holds a value on every path to it (Bounds' presence): no null reaches
/// its `unreachable`.
pub fn present(c: *Context, file: Project.FileId, unwrap: Ast.Node.Index) Context.Error!bool {
    return Bounds.cleared(c, file, unwrap, .present);
}

/// A `catch` whose operand never fails on any path to it (Bounds' failing exits of its call's
/// callee, ruled out by what the call is given): its answer never runs.
pub fn unfailing(c: *Context, file: Project.FileId, node: Ast.Node.Index) Context.Error!bool {
    return Bounds.cleared(c, file, node, .unfailing);
}
