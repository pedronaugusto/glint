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
    /// `own.Lent`: a copy of an owner's payload lent out, not the holder's to release.
    lent,
    must_use,
    shared,
    /// Generational storage: `Pool`, `SlotMap`, `DenseSlotMap`, `SecondaryMap`.
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
};

/// Aegis as programs import it. A declaration is aegis's when the path a program writes from the
/// module root reaches it, so recognition survives any revision that keeps its public names and
/// reports one that drops them (Context.drift). The same members are listed once per way aegis
/// is imported: the root, and each namespace module a program may depend on alone.
pub const library: Lib = .{ .modules = &modules };
/// Aegis's package, as its `build.zig.zon` names it (`Facts.known`): its own files are not the
/// program's, as the analyses know aegis by its declarations, under whatever name it is
/// imported. Its fingerprint stays the same in every revision.
pub const package: Facts.Package = .{ .name = "aegis", .fingerprint = 0x5e23831cba68ccae };
const Lib = Library(Kind);
const modules = [_]Lib.Module{
    .{ .name = "aegis", .members = &root_members },
    .{ .name = "aegis.secret", .members = &secret_members },
    .{ .name = "aegis.sync", .members = &sync_members },
    .{ .name = "aegis.int", .members = &int_members },
    .{ .name = "aegis.id", .members = &id_members },
    .{ .name = "aegis.units", .members = &units_members },
};
const secret_members = [_]Lib.Member{
    .{ .path = "Secret", .role = .secret },
    .{ .path = "SecretBytes", .role = .bytes },
    .{ .path = "SecretBytes.Writer", .role = .bytes_writer, .required = false },
    .{ .path = "Choice", .role = .choice, .required = false },
};
const sync_members = [_]Lib.Member{
    .{ .path = "Guarded", .role = .guarded },
    .{ .path = "BlockingGuarded", .role = .guarded },
    .{ .path = "RwGuarded", .role = .guarded },
    .{ .path = "SpinRwGuarded", .role = .guarded },
    .{ .path = "Condition", .role = .condition },
    .{ .path = "Once", .role = .once },
    .{ .path = "Lazy", .role = .once },
    .{ .path = "Confined", .role = .confined },
    .{ .path = "Shared", .role = .shared, .required = false },
    .{ .path = "Atomic", .role = .atomic, .required = false },
    .{ .path = "InitContext", .role = .context, .required = false },
    .{ .path = "Order.Context", .role = .context, .required = false },
    .{ .path = "Order.Ordered", .role = .guarded, .required = false },
};
const int_members = [_]Lib.Member{
    .{ .path = "Checked", .role = .scalar },
    .{ .path = "Saturating", .role = .scalar },
    .{ .path = "Ranged", .role = .scalar },
};
const id_members = [_]Lib.Member{
    .{ .path = "Id", .role = .scalar },
    .{ .path = "NonZero", .role = .scalar },
    .{ .path = "Counter", .role = .issuer },
};
const units_members = [_]Lib.Member{
    .{ .path = "Count", .role = .scalar },
    .{ .path = "Bytes", .role = .scalar },
    .{ .path = "Bits", .role = .scalar },
    .{ .path = "Duration", .role = .scalar },
    .{ .path = "Instant", .role = .scalar },
};
const root_members = [_]Lib.Member{
    .{ .path = "Secret", .role = .secret },
    .{ .path = "SecretBytes", .role = .bytes },
    .{ .path = "SecretBytes.Writer", .role = .bytes_writer, .required = false },
    .{ .path = "Guarded", .role = .guarded },
    .{ .path = "BlockingGuarded", .role = .guarded },
    .{ .path = "RwGuarded", .role = .guarded },
    .{ .path = "SpinRwGuarded", .role = .guarded },
    .{ .path = "Condition", .role = .condition },
    .{ .path = "Once", .role = .once },
    .{ .path = "Lazy", .role = .once },
    .{ .path = "Confined", .role = .confined },
    .{ .path = "int.Checked", .role = .scalar },
    .{ .path = "int.Saturating", .role = .scalar },
    .{ .path = "int.Ranged", .role = .scalar },
    .{ .path = "id.Id", .role = .scalar },
    .{ .path = "id.NonZero", .role = .scalar },
    .{ .path = "id.Counter", .role = .issuer },
    .{ .path = "units.Count", .role = .scalar },
    .{ .path = "units.Bytes", .role = .scalar },
    .{ .path = "units.Bits", .role = .scalar },
    .{ .path = "units.Duration", .role = .scalar },
    .{ .path = "units.Instant", .role = .scalar },
    .{ .path = "secret.Choice", .role = .choice },
    .{ .path = "Shared", .role = .shared },
    .{ .path = "Atomic", .role = .atomic },
    .{ .path = "InitContext", .role = .context },
    .{ .path = "Order.Context", .role = .context },
    .{ .path = "Order.Ordered", .role = .guarded },
    .{ .path = "bounded.Array", .role = .inline_store },
    .{ .path = "bounded.Ring", .role = .inline_store },
    // `Queue` and `QueueBuffer` name `Ring` and `RingBuffer` through 0.2; 0.3 keeps one name each.
    .{ .path = "bounded.Queue", .role = .inline_store, .required = false },
    .{ .path = "bounded.Buffer", .role = .buffer },
    .{ .path = "bounded.RingBuffer", .role = .buffer },
    .{ .path = "bounded.QueueBuffer", .role = .buffer, .required = false },
    .{ .path = "bounded.Limit", .role = .limit },
    .{ .path = "bounded.Budget", .role = .budget },
    .{ .path = "bounded.Budget.Reservation", .role = .reservation },
    .{ .path = "own.Owned", .role = .owned },
    .{ .path = "own.OwnedIo", .role = .owned },
    .{ .path = "own.Lent", .role = .lent, .required = false },
    .{ .path = "own.MustUse", .role = .must_use },
    .{ .path = "handle.Pool", .role = .slots },
    .{ .path = "handle.SlotMap", .role = .slots },
    .{ .path = "handle.DenseSlotMap", .role = .slots },
    .{ .path = "handle.SecondaryMap", .role = .slots },
    .{ .path = "handle.Domain", .role = .issuer },
    .{ .path = "handle.Index", .role = .scalar },
    .{ .path = "state.Machine.At", .role = .stage },
    .{ .path = "state.Machine.Runtime", .role = .machine },
    .{ .path = "scope.Table", .role = .table },
    .{ .path = "scope.Table.Scope", .role = .scope },
    .{ .path = "scope.Ref", .role = .ref },
    .{ .path = "input.Untrusted", .role = .untrusted },
    .{ .path = "err.PublicSource", .role = .public_source, .required = false },
};

/// Finds known owners through lexical aliases, declared types and exact constructors.
/// Generic argument equality, alias effects and control flow are deliberately not inferred.
pub fn kind(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!?Kind {
    if (depth == 64) return null;
    const tree = &c.project.at(file).file.tree;
    const model = &c.project.at(file).model;
    if (tree.fullPtrType(node)) |ptr| return kind(c, file, ptr.ast.child_type, depth + 1);
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return null;
            const index = ref.declaration orelse return null;
            const decl = model.declarations[@backingInt(index)];
            if (decl.kind == .parameter) return kind(c, file, decl.node, depth + 1);
            if (decl.kind == .capture) return captured(c, file, decl.node, decl.token, depth + 1);
            if (decl.kind == .field) {
                const field = tree.fullContainerField(decl.node).?;
                if (field.ast.type_expr.unwrap()) |t| return kind(c, file, t, depth + 1);
            }
            if (tree.fullVarDecl(decl.node)) |v| {
                if (v.ast.type_node.unwrap()) |t| if (try kind(c, file, t, depth + 1)) |k| return k;
                if (v.ast.init_node.unwrap()) |init| return kind(c, file, init, depth + 1);
            }
        },
        .@"try", .address_of, .deref, .optional_type => return kind(c, file, tree.nodeData(node).node, depth + 1),
        .unwrap_optional => return kind(c, file, tree.nodeData(node).node_and_token[0], depth + 1),
        .@"orelse", .@"catch" => return kind(c, file, tree.nodeData(node).node_and_node[0], depth + 1),
        .error_union => return kind(c, file, tree.nodeData(node).node_and_node[1], depth + 1),
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (guardType(try Model.identifier(c.allocator, tree.tokenSlice(data[1]))) and try kind(c, file, data[0], depth + 1) == .guarded) return .guard;
            if (try typeRole(c, try c.facts.resolve(file, node))) |k| return k;
            // A member reached through a module import or another file's alias names its own
            // declaration: its type expression is read where it is written, which a value
            // resolved through a type function's call cannot always be.
            const decl = (try c.facts.definition(file, node)) orelse return null;
            const record = c.project.at(decl.file).model.declarations[@backingInt(decl.index)];
            const written = &c.project.at(decl.file).file.tree;
            if (record.kind == .field) {
                const field = written.fullContainerField(record.node).?;
                if (field.ast.type_expr.unwrap()) |t| return kind(c, decl.file, t, depth + 1);
                return null;
            }
            if (written.fullVarDecl(record.node)) |v| {
                if (v.ast.type_node.unwrap()) |t| if (try kind(c, decl.file, t, depth + 1)) |k| return k;
                if (v.ast.init_node.unwrap()) |init| return kind(c, decl.file, init, depth + 1);
            }
            return null;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return typeRole(c, try c.facts.resolve(file, node)),
        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
                const data = tree.nodeData(call.ast.fn_expr).node_and_token;
                const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
                if (std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "fromRaw") or std.mem.eql(u8, name, "adopt")) return kind(c, file, data[0], depth + 1);
                if (acquisition(name) and try kind(c, file, data[0], depth + 1) == .guarded) return .guard;
            }
            const decl = (try c.facts.definition(file, call.ast.fn_expr)) orelse return null;
            const origin = (try c.facts.origin(decl)) orelse return null;
            if (try c.role(library, .{ .function = origin })) |k| return k;
            // A function of the program's own is what its declared result says, whether it is
            // an ordinary function or a method of a type a type function returns.
            const record = c.project.at(origin.file).model.declarations[@backingInt(origin.index)];
            if (record.kind != .function) return null;
            const written = &c.project.at(origin.file).file.tree;
            var proto_buffer: [1]Ast.Node.Index = undefined;
            const proto = written.fullFnProto(&proto_buffer, record.node) orelse return null;
            const result = proto.ast.return_type.unwrap() orelse return null;
            return kind(c, origin.file, result, depth + 1);
        },
        else => {},
    }
    return null;
}
/// The guard types a guarded owner declares: one guard, or a reader's and a writer's.
pub fn guardType(name: []const u8) bool {
    for ([_][]const u8{ "Guard", "ReadGuard", "WriteGuard" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// The operations by which a guarded owner gives a guard: every acquire, blocking or
/// spinning, cancelable or not, tried or waited for, and a reader's or a writer's.
pub fn acquisition(name: []const u8) bool {
    for ([_][]const u8{ "acquire", "acquireUncancelable", "acquireScheduling", "acquireYielding", "acquireYieldingUncancelable", "tryAcquire", "read", "write", "readUncancelable", "writeUncancelable", "acquireOrdered", "acquireOrderedUncancelable", "readOrdered", "writeOrdered", "readOrderedUncancelable", "writeOrderedUncancelable" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
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
