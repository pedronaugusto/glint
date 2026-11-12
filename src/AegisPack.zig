//! Optional explicitly adopted published-type obligations. No security or lifetime proof.
const std = @import("std");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Contract = @import("AegisContract.zig");
const Ids = @import("AegisRules.zig");
const Danger = @import("Danger.zig");
const Shapes = @import("DangerShapes.zig");
const Rule = @import("Rule.zig").Rule;
// The danger rules (designs/aegis.md §7): each finds where its danger exists and aegis's type is
// the answer, from what the code resolves to.
// Identities no rule of the pack carries, named here only for preflight's policy, which lists them:
// A006 and A018 (removed in 0.8), and the rules aegis now declares itself or that went with the
// flow engine (AegisRules).
pub const recursion = Ids.recursion;
pub const diagnostics = Ids.diagnostics;
pub const shared_state = Ids.shared_state;
pub const untrusted_input = Ids.untrusted_input;
pub const integers = Ids.integers;
pub const bounded_work = Ids.bounded_work;
pub const contracts = Ids.contracts;
pub const cancellation = Ids.cancellation;
pub const lock_order = Ids.lock_order;
/// The danger rules: each finds where a danger exists and aegis's type is the answer.
pub const danger = [_]Rule{ lifetimes, identity, unsafe_set };
pub const lifetimes = Ids.lifetimes;
pub const identity = Ids.identity;
pub const unsafe_set = Ids.unsafe_set;
/// Aegis's package, as its `build.zig.zon` names it: a caller states it for aegis's files.
pub const package = Contract.package;
/// The roles the pack reads from what aegis declares, and aegis as a library of them: a project's
/// own rule reads a role through `RuleContext.role(library, value)`.
pub const Role = Contract.Kind;
pub const library = Contract.library;
/// The first file outside aegis whose import reaches aegis (`Facts.packageRoots`): a file of
/// aegis's package, by the identity the caller states, whatever the program names it after. A
/// module of aegis's name that is not of aegis's package is not aegis.
pub fn importer(gpa: std.mem.Allocator, project: *const Project) Facts.ResolveError!?Project.FileId {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var facts: Facts = .{ .project = project, .gpa = arena.allocator(), .known = Contract.package };
    const roots = try facts.packageRoots(Contract.package);
    for (project.imports) |mapping| {
        if (!mapping.in.inProgram() or facts.knownFile(mapping.from)) continue;
        if (std.mem.findScalar(Project.FileId, roots, mapping.target) != null) return mapping.from;
    }
    return null;
}

pub const rules = [_]Context.Rule{
    .{ .definition = .{ .id = lifetimes, .name = "A014", .group = .family_policy, .purpose = "pointer that outlives what it points into", .exception = .aegis }, .check = checkLifetimes },
    .{ .definition = .{ .id = identity, .name = "A016", .group = .family_policy, .purpose = "identifying integers of one type that one may pass for another", .exception = .aegis }, .check = checkIdentity },
    .{ .definition = .{ .id = unsafe_set, .name = "A019", .group = .family_policy, .purpose = "operation Zig leaves unchecked", .exception = .aegis }, .check = checkUnsafeSet },
};
fn checkLifetimes(c: *Context) Context.Error!void {
    if (!try begin(c, lifetimes)) return;
    try Danger.lifetimes(c, lifetimes);
}
fn checkIdentity(c: *Context) Context.Error!void {
    if (try begin(c, identity)) try Shapes.identity(c, identity);
}
fn checkUnsafeSet(c: *Context) Context.Error!void {
    if (!try begin(c, unsafe_set)) return;
    try Danger.unsafeSet(c, unsafe_set);
}
/// Starts a check of this file. What a `lint_rules` it declares says that glint cannot read is
/// reported where it is written, in whatever package (`ownRules`). The library's own files are
/// its safe-type internals; a root whose roles are not all read is reported where the library is
/// imported, so a renamed declaration cannot make a gate quietly stop seeing it.
fn begin(c: *Context, rule: Rule) Context.Error!bool {
    if (try c.inLibrary(Contract.library, c.file)) return false;
    if (try c.drift(Contract.library)) |gap| try c.undecided(rule, gap.start, .unresolved, gap.detail);
    // Every rule of the pack judges a generic at its bindings: one on the surface that nothing
    // the run compiles binds is undecided at its name (main's ruling, 2026-11-04).
    const tree = try c.project.syntax(try c.source());
    for (c.project.at(c.file).model.declarations, 0..) |decl, i| {
        if (decl.kind != .function) continue;
        if (!try c.facts.unboundOnSurface(.{ .file = c.file, .index = @fromBackingInt(@intCast(i)) })) continue;
        try c.undecided(rule, tree.tokenStart(decl.token), .unresolved, Facts.unbound_generic);
    }
    return true;
}
