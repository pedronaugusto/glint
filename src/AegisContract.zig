//! Declaration identity for the published operation contract, never name taint.
const std = @import("std");
const Model = @import("Model.zig");
const Project = @import("Project.zig");
const Context = @import("RuleContext.zig");
const Ast = std.zig.Ast;
pub const Kind = enum { secret, bytes, guarded, guard, scalar };
pub const pinned = "a5d17d0f346d8edacce34b86eea953eb096931da";
const hashes = [_][]const u8{
    "8570c4d9a306526ac74ddb07ce0ca84e36936f713e83d43aee39e72fb8a7a87a",
    "941fc6878aaa56603a12c52c67a9e612203f44088c1838c67f1f910e18a5c770",
    "08b73fdc1ba4763ba007fa489dced55658e8b87c422c68874b1702462ceade30",
    "b0abae411c276b35407f9e7d7a5ebfe2629bc1208ef70bc7edf19a07f59b6f3d",
    "a41654621817cf394112efd6b279c70de89dece1c7a6fc7197bdc06f9b42a557",
    "ed1843dab957555d5e48412cdaabc0ed6b3c8223c39dfbf98691e7ffaec4be37",
};
pub fn source(c: *Context, file: Project.FileId) Context.Error!?usize {
    const digest = try c.sourceDigest(file);
    const hex = std.fmt.bytesToHex(&digest, .lower);
    for (hashes, 0..) |hash, i| if (std.mem.eql(u8, hash, &hex)) return i;
    return null;
}

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
            const value = try c.facts.resolve(file, node);
            const container = switch (value) {
                .container, .instance => |v| v,
                else => return null,
            };
            if (try source(c, container.file) == 2 and container.scope == 0) return .bytes;
        },
        .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {
            const value = try c.facts.resolve(file, node);
            if (value == .container and try source(c, value.container.file) == 2 and value.container.scope == 0) return .bytes;
        },
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
            const contract = try source(c, origin.file) orelse return null;
            const record = c.project.models[origin.file.raw()].declarations[origin.index];
            if (record.kind != .function or record.scope != 0) return null;
            if (contract == 0 and std.mem.eql(u8, record.name, "Secret")) return .secret;
            if (contract == 1 and std.mem.eql(u8, record.name, "Guarded")) return .guarded;
            if (contract >= 3) {
                for ([_][]const u8{ "Id", "NonZero", "Counter", "Count", "Bytes", "Bits", "Duration", "Instant", "Checked", "Saturating", "Ranged" }) |name| if (std.mem.eql(u8, record.name, name)) return .scalar;
            }
        },
        else => {},
    }
    return null;
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
