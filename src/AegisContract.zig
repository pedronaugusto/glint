//! Declaration identity for the published operation contract, never name taint.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Library = @import("Library.zig").Library;
const Ast = std.zig.Ast;
pub const Kind = enum {
    secret,
    bytes,
    /// `SecretBytes.Writer`: a `std.Io.Writer` into a `SecretBytes`, which it borrows.
    bytes_writer,
    guarded,
    guard,
    /// An `Order`'s ranked capability, a guard whose acquisition checks the task's rank order: a
    /// guard to every check (`isGuard`).
    ranked_guard,
    /// A guard's release handed past its frame, `Guard.handOff`'s `Handoff`: released once.
    handoff,
    scalar,
    condition,
    once,
    confined,
    /// Inline bounded storage: `Array`, `Ring` (`Queue`).
    inline_store,
    /// Bounded storage over a caller's or an allocated buffer: `Buffer`, `RingBuffer` (`QueueBuffer`).
    buffer,
    limit,
    budget,
    /// A budget's reservation, released once.
    reservation,
    /// `Owned` and `OwnedIo`.
    owned,
    /// A std resource (`Io.File`, `Io.Dir`, `Io.net.Stream`, `Io.net.Server`, `process.Child`)
    /// acquired raw by a call: no type of aegis's, its release std's `close` (A003).
    std_handle,
    /// `own.Lent`: a copy of an owner's payload lent out, not the holder's to release.
    lent,
    must_use,
    shared,
    /// Storage on a region or a buffer its holder owns: `SlotPool` (0.2's `Pool` and `SlotMap`),
    /// `RunPool`, `DenseSlotMap`, `SecondaryMap`.
    slots,
    /// `handle.Domain`, which issues instances.
    issuer,
    /// A typestate machine's staged payload, `Machine.At`.
    stage,
    /// A typestate machine's payload beside its state, `Machine.Runtime`.
    machine,
    /// `scope.Table`, the creator's record of its scopes.
    table,
    /// One open scope, `Table.Scope`.
    scope,
    /// A reference made in a scope, `scope.Ref`.
    ref,
    untrusted,
    choice,
    /// `Atomic`: one cell, shared by pointer.
    atomic,
    /// A logical task's diagnostic context: `Order(...).Context`, `InitContext`.
    context,
    /// Runtime text classified public, `err.PublicSource`: made by `classify`, whose reason is
    /// the review a literal skips.
    public_source,
    /// A record of the program holding owners by value in its fields (`heldInRecord`), no type of
    /// aegis's: released by a call of its own that releases each of them on every exit, read by
    /// releases.zig (A003).
    record,
};

/// Aegis's roles, as aegis declares them in its root's `lint_rules` (glint-design §12): each
/// type's role by its declaration, read through `Facts.publication`. A role a revision of aegis
/// no longer declares, or one it declares that does not resolve, is a gap that rule reports where
/// aegis is imported (Context.drift); aegis's own lint reports its problems where they are written.
pub const library: Library(Kind) = .{ .package = package };
/// Aegis's package, as its `build.zig.zon` names it (`Facts.known`): its own files are not the
/// program's, as the analyses know aegis by its declarations, under whatever name it is
/// imported. Its fingerprint stays the same in every revision.
pub const package: Facts.Package = .{ .name = "aegis", .fingerprint = 0x5e23831cba68ccae };

/// Finds known owners through lexical aliases, declared types and exact constructors.
/// Generic argument equality, alias effects and control flow are deliberately not inferred.
/// Null is no role shown, a declaration that does not resolve included: a caller clears only on
/// a role this finds, so what it cannot read keeps the caller's finding.
pub fn kind(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!?Kind {
    if (depth == 64) return null;
    const tree = &c.project.at(file).file.tree;
    // What the expression is, or is a type of, by the value it resolves to (through `?`, `!`, a
    // pointer, an array: PackageRules.role).
    if (try typeRole(c, try c.facts.resolve(file, node))) |k| return k;
    // What resolve cannot always read: the declaration a name stands for, read where it is
    // written, and what a call's callee says it makes.
    switch (Facts.accesses.formOf(tree.nodeTag(node))) {
        .pointer_type => return kind(c, file, tree.fullPtrType(node).?.ast.child_type, depth + 1), // unreachable: the form is a pointer type's
        .tried, .address_of, .deref, .optional_type => return kind(c, file, tree.nodeData(node).node, depth + 1),
        .unwrap_optional => return kind(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"orelse", .@"catch" => return kind(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .error_union => return kind(c, file, tree.nodeData(node).node_and_node[1], depth + 1),
        // A name, or a member reached through a module import or another file's alias: its own
        // declaration, its type expression read where it is written, which a value resolved
        // through a type function's call cannot always be.
        .leaf, .member => {
            const decl = switch (try c.facts.definition(file, node)) {
                .decl => |found| found,
                .none, .unknown => return null,
            };
            const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            const written = &c.project.at(decl.file).file.tree;
            switch (record.kind) {
                .parameter => return kind(c, decl.file, record.node, depth + 1),
                .capture => return captured(c, decl.file, record.node, record.token, depth + 1),
                .field => {
                    const field = c.project.at(decl.file).model.containerField(written, record.node).?; // unreachable: a field's declaration is a container's field
                    if (field.ast.type_expr.unwrap()) |t| return kind(c, decl.file, t, depth + 1);
                    return null;
                },
                else => {},
            }
            if (written.fullVarDecl(record.node)) |v| {
                if (v.ast.type_node.unwrap()) |t| if (try kind(c, decl.file, t, depth + 1)) |k| return k;
                if (v.ast.init_node.unwrap()) |init| return kind(c, decl.file, init, depth + 1);
            }
            return null;
        },
        .call => {
            // What the call makes, by its callee: one aegis declares a role for, or a function of
            // the program's own, which is what its declared result says, whether it is an
            // ordinary function or a method of a type a type function returns. Never the
            // callee's spelling.
            const origin = switch ((try Facts.calls.at(c.facts, file, node) orelse return null).callee) {
                .function => |function| function,
                .choice, .any => return null,
            };
            if (try c.role(library, .{ .function = origin })) |k| return k;
            const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
            if (record.kind != .function) return null;
            const written = &c.project.at(origin.file).file.tree;
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = written.fullFnProto(&proto_buffer, record.node) orelse return null;
            const result = proto.ast.return_type.unwrap() orelse return null;
            return kind(c, origin.file, result, depth + 1);
        },
        else => return null,
    }
}
/// Whether a role is a guard's: an owner's guard, or an Order's ranked capability. Every guard
/// check asks this, so none forgets the ranked one.
pub fn isGuard(k: ?Kind) bool {
    return k == .guard or k == .ranked_guard;
}

/// What calling `decl` acquires (`acquired`): no guard, a guard, a ranked guard, or not known.
pub const Acquisition = enum { no, plain, ranked, unknown };
/// Whether `decl` acquires a guard: a function whose declared result, through `!`, `?` and the
/// wrapper aegis declares (`MustUse(Guard, ...)`, by its role), is a type whose role is a guard's
/// (aegis's `lint_rules`, never the function's name). A result that does not resolve, or a
/// wrapper whose payload does not, is unknown, never no guard.
pub fn acquired(c: *Context, decl: Facts.Decl) Context.Error!Acquisition {
    const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
    if (record.kind != .function) return .no;
    const tree = &c.project.at(decl.file).file.tree;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, record.node) orelse return .unknown;
    return resultGuard(c, try c.facts.resolve(decl.file, proto.ast.return_type.unwrap() orelse return .no), 0);
}
/// What a result of type `value` acquires: through `!` and `?`, a guard or a ranked guard by its
/// role, and the wrapper aegis declares (`MustUse(Guard, ...)`, by its role) by what it holds: a
/// guard if a field of it holds one, unknown if one does not resolve. A choice is what each of
/// its parts acquires, unknown where they differ.
fn resultGuard(c: *Context, value: Facts.Value, depth: usize) Context.Error!Acquisition {
    if (depth == 16) return .unknown;
    switch (value) {
        .unknown => return .unknown,
        .optional, .error_union => |inner| return resultGuard(c, inner.*, depth + 1),
        .alternatives => |each| {
            var found: ?Acquisition = null;
            for (each) |one| {
                const part = try resultGuard(c, one, depth + 1);
                if (found != null and found.? != part) return .unknown;
                found = part;
            }
            return found orelse .unknown;
        },
        else => {},
    }
    return switch ((try c.role(library, value)) orelse return .no) {
        .guard => .plain,
        .ranked_guard => .ranked,
        .must_use => switch (value) {
            .container, .instance => |wrapper| held: {
                var unknown = false;
                for (try c.facts.heldFields(wrapper)) |field| switch (try resultGuard(c, field.value, depth + 1)) {
                    .no => {},
                    .unknown => unknown = true,
                    .plain, .ranked => |guard| break :held guard,
                };
                break :held if (unknown) .unknown else .no;
            },
            .alternatives => unreachable, // unreachable: a choice is read part by part above
            // A wrapper reached as a pointer to it: what it holds is not read here.
            else => .unknown,
        },
        else => .no,
    };
}

/// What a name bound by `if (x) |name|` or `while (x) |name|` holds: the payload of `x`, which
/// is `x`'s own kind seen through its optional or error union. Other captures stay unknown.
fn captured(c: *Context, file: Project.FileId, node: Ast.Node.Index, name: Ast.TokenIndex, depth: usize) Context.Error!?Kind {
    const tree = &c.project.at(file).file.tree;
    if (tree.fullIf(node)) |branch| {
        const payload = branch.payload_token orelse return null;
        if (payload != name and payload + 1 != name) return null;
        return kind(c, file, branch.ast.cond_expr, depth + 1);
    }
    if (tree.fullWhile(node)) |branch| {
        const payload = branch.payload_token orelse return null;
        if (payload != name and payload + 1 != name) return null;
        return kind(c, file, branch.ast.cond_expr, depth + 1);
    }
    return null;
}
/// A published type function is recognized where it is called; named alone it is no value.
fn typeRole(c: *Context, value: Facts.Value) Context.Error!?Kind {
    return if (value == .function) null else c.role(library, value);
}
pub fn owner(c: *Context, node: Ast.Node.Index) Context.Error!?Kind {
    return kind(c, c.file, node, 0);
}
/// Lexical root identity; member paths are not collapsed to their enclosing owner.
pub fn local(c: *Context, node: Ast.Node.Index) ?Model.Declaration.Id {
    const model = &c.project.at(c.file).model;
    const ref = model.reference(node) orelse return null;
    return ref.declaration;
}
