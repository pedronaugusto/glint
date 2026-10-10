//! Declaration identity for the published operation contract, never name taint.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Facts = @import("Facts.zig");
const Context = @import("RuleContext.zig");
const Library = @import("Library.zig").Library;
const Ast = std.zig.Ast;
pub const Kind = enum { secret, bytes, guarded, guard, scalar };

/// Aegis as programs import it. A declaration is aegis's when the path a program writes from the
/// module root reaches it, so recognition survives any revision that keeps its public names and
/// reports one that drops them (Context.drift). The same members are listed once per way aegis
/// is imported: the root, and each namespace module a program may depend on alone.
pub const library: Lib = .{ .modules = &modules };
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
};
const sync_members = [_]Lib.Member{.{ .path = "Guarded", .role = .guarded }};
const int_members = [_]Lib.Member{
    .{ .path = "Checked", .role = .scalar },
    .{ .path = "Saturating", .role = .scalar },
    .{ .path = "Ranged", .role = .scalar },
};
const id_members = [_]Lib.Member{
    .{ .path = "Id", .role = .scalar },
    .{ .path = "NonZero", .role = .scalar },
    .{ .path = "Counter", .role = .scalar },
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
    .{ .path = "Guarded", .role = .guarded },
    .{ .path = "int.Checked", .role = .scalar },
    .{ .path = "int.Saturating", .role = .scalar },
    .{ .path = "int.Ranged", .role = .scalar },
    .{ .path = "id.Id", .role = .scalar },
    .{ .path = "id.NonZero", .role = .scalar },
    .{ .path = "id.Counter", .role = .scalar },
    .{ .path = "units.Count", .role = .scalar },
    .{ .path = "units.Bytes", .role = .scalar },
    .{ .path = "units.Bits", .role = .scalar },
    .{ .path = "units.Duration", .role = .scalar },
    .{ .path = "units.Instant", .role = .scalar },
};

/// Finds known owners through lexical aliases, declared types and exact constructors.
/// Generic argument equality, alias effects and control flow are deliberately not inferred.
pub fn kind(c: *Context, file: Project.FileId, node: Ast.Node.Index, depth: usize) Context.Error!?Kind {
    if (depth == 64) return null;
    const tree = &c.project.files[file.raw()].tree;
    const model = &c.project.models[file.raw()];
    if (tree.fullPtrType(node)) |ptr| return kind(c, file, ptr.ast.child_type, depth + 1);
    switch (tree.nodeTag(node)) {
        .identifier => {
            const ref = model.reference(node) orelse return null;
            const index = ref.declaration orelse return null;
            const decl = model.declarations[index];
            if (decl.kind == .parameter) return kind(c, file, decl.node, depth + 1);
            if (decl.kind == .field) {
                const field = tree.fullContainerField(decl.node).?;
                if (field.ast.type_expr.unwrap()) |t| return kind(c, file, t, depth + 1);
            }
            if (tree.fullVarDecl(decl.node)) |v| {
                if (v.ast.type_node.unwrap()) |t| if (try kind(c, file, t, depth + 1)) |k| return k;
                if (v.ast.init_node.unwrap()) |init| return kind(c, file, init, depth + 1);
            }
        },
        .@"try", .address_of, .deref => return kind(c, file, tree.nodeData(node).node, depth + 1),
        .field_access => {
            const data = tree.nodeData(node).node_and_token;
            if (std.mem.eql(u8, try Model.identifier(c.allocator, tree.tokenSlice(data[1])), "Guard") and try kind(c, file, data[0], depth + 1) == .guarded) return .guard;
            return typeRole(c, try c.facts.resolve(file, node));
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => return typeRole(c, try c.facts.resolve(file, node)),
        .call_one, .call_one_comma, .call, .call_comma => {
            var buffer: [1]Ast.Node.Index = undefined;
            const call = tree.fullCall(&buffer, node).?;
            if (tree.nodeTag(call.ast.fn_expr) == .field_access) {
                const data = tree.nodeData(call.ast.fn_expr).node_and_token;
                const name = try Model.identifier(c.allocator, tree.tokenSlice(data[1]));
                if (std.mem.eql(u8, name, "init") or std.mem.eql(u8, name, "fromRaw") or std.mem.eql(u8, name, "adopt")) return kind(c, file, data[0], depth + 1);
                if (std.mem.eql(u8, name, "acquire") and try kind(c, file, data[0], depth + 1) == .guarded) return .guard;
            }
            const decl = (try c.facts.definition(file, call.ast.fn_expr)) orelse return null;
            const origin = (try c.facts.origin(decl)) orelse return null;
            return c.role(library, .{ .function = origin });
        },
        else => {},
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
pub fn local(c: *Context, node: Ast.Node.Index) ?u32 {
    const model = &c.project.models[c.file.raw()];
    const ref = model.reference(node) orelse return null;
    return ref.declaration;
}
