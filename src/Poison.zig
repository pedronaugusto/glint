//! Selected Z030 debug-poisoning shapes in std ZIR order. This is hygiene,
//! never a lifetime proof; destroy spelling is the inherited heuristic.
const std = @import("std");
const Project = @import("Project.zig");
const Model = @import("Model.zig");
const Ast = std.zig.Ast;
const Zir = std.zig.Zir;

pub const Verdict = union(enum) { irrelevant, accepted, warning: []const u8, unknown: []const u8, budget };
const Scan = struct {
    tree: *const Ast,
    model: *const Model,
    zir: Zir,
    baseline: Ast.Node.Index,
    receiver: u32,
    remaining: usize = 100_000,
    warning: ?[]const u8 = null,
    unknown: bool = false,
    exhausted: bool = false,

    fn receiverNode(self: *const Scan, node: Ast.Node.Index) bool {
        const ref = self.model.reference(node) orelse return false;
        return ref.declaration == self.receiver;
    }
    fn poison(self: *const Scan, node: Ast.Node.Index) bool {
        if (self.tree.nodeTag(node) != .assign) return false;
        const pair = self.tree.nodeData(node).node_and_node;
        if (self.tree.nodeTag(pair[0]) != .deref or self.tree.nodeTag(pair[1]) != .identifier) return false;
        return self.receiverNode(self.tree.nodeData(pair[0]).node) and std.mem.eql(u8, self.tree.tokenSlice(self.tree.nodeMainToken(pair[1])), "undefined");
    }
    fn destroy(self: *const Scan, node: Ast.Node.Index) bool {
        var cb: [1]Ast.Node.Index = undefined;
        const call = self.tree.fullCall(&cb, node) orelse return false;
        if (self.tree.nodeTag(call.ast.fn_expr) != .field_access or call.ast.params.len != 1) return false;
        const name = self.tree.nodeData(call.ast.fn_expr).node_and_token[1];
        return std.mem.eql(u8, self.tree.tokenSlice(name), "destroy") and self.receiverNode(call.ast.params[0]);
    }
    fn body(self: *Scan, instructions: []const Zir.Inst.Index, initial: u3, depth: usize) u3 {
        if (depth >= 128) {
            self.exhausted = true;
            return initial;
        }
        var states = initial;
        for (instructions) |inst| {
            if (self.remaining == 0) {
                self.exhausted = true;
                return states;
            }
            self.remaining -= 1;
            if (states == 0) break;
            const i = @backingInt(inst); // safe: enum identities index their owning frozen tables without narrowing.
            const tag = self.zir.instructions.items(.tag)[i];
            const data = self.zir.instructions.items(.data)[i];
            switch (tag) {
                .store_node, .store_to_inferred_ptr => {
                    const node = data.pl_node.src_node.toAbsolute(self.baseline);
                    if (self.poison(node)) {
                        if (states & 4 != 0) self.warning = "poisoning write follows receiver destroy shape";
                        states = if (states & 3 != 0) 2 else states;
                    }
                },
                .call, .field_call => {
                    if (self.destroy(data.pl_node.src_node.toAbsolute(self.baseline))) states = 4;
                },
                .ret_node, .ret_load, .ret_implicit, .ret_err_value => {
                    if (states & 1 != 0) self.warning = "deinit return lacks receiver poisoning or destroy shape";
                    states = 0;
                },
                .condbr, .condbr_inline => {
                    const extra = self.zir.extraData(Zir.Inst.CondBr, data.pl_node.payload_index);
                    const yes = self.zir.bodySlice(extra.end, extra.data.then_body_len);
                    const no = self.zir.bodySlice(extra.end + extra.data.then_body_len, extra.data.else_body_len);
                    states = self.body(yes, states, depth + 1) | self.body(no, states, depth + 1);
                },
                .block, .block_inline => {
                    const extra = self.zir.extraData(Zir.Inst.Block, data.pl_node.payload_index);
                    states = self.body(self.zir.bodySlice(extra.end, extra.data.body_len), states, depth + 1);
                },
                .@"defer" => states = self.body(self.zir.bodySlice(data.@"defer".index, data.@"defer".len), states, depth + 1),
                .@"try", .try_ptr => {
                    const extra = self.zir.extraData(Zir.Inst.Try, data.pl_node.payload_index);
                    _ = self.body(self.zir.bodySlice(extra.end, extra.data.body_len), states, depth + 1);
                },
                .loop, .switch_block, .switch_block_ref, .switch_block_err_union, .repeat, .repeat_inline => self.unknown = true,
                else => {},
            }
        }
        return states;
    }
};

pub fn analyze(a: std.mem.Allocator, project: *const Project, file: Project.FileId, decl: Model.Declaration) std.mem.Allocator.Error!Verdict {
    if (decl.kind != .function or !std.mem.eql(u8, decl.name, "deinit")) return .irrelevant;
    const index = @backingInt(file); // safe: enum identities index their owning frozen tables without narrowing.
    const tree = &project.files[index].tree;
    const model = &project.models[index];
    var buffer: [1]Ast.Node.Index = undefined;
    const function = tree.fullFnProto(&buffer, decl.node).?;
    var it = function.iterate(tree);
    const param = it.next() orelse return .irrelevant;
    if (tree.fullPtrType(param.type_expr orelse return .irrelevant) == null) return .irrelevant;
    const token = param.name_token orelse return .irrelevant;
    const receiver = model.lookup(model.token_scopes[token], tree.tokenSlice(token), token) orelse return .{ .unknown = "receiver binding unavailable" };
    const lowered = decl.lowered orelse return .{ .unknown = "deinit declaration not lowered" };
    const zir = project.files[index].zir.?;
    var contents: Zir.DeclContents = .init;
    defer contents.deinit(a);
    try zir.findTrackable(a, &contents, lowered);
    const fn_inst = contents.func_decl orelse return .{ .unknown = "deinit body unavailable" };
    var scan: Scan = .{ .tree = tree, .model = model, .zir = zir, .baseline = zir.getDeclaration(lowered).src_node, .receiver = receiver };
    const remaining = scan.body(zir.getFnInfo(fn_inst).body, 1, 0);
    if (scan.exhausted) return .budget;
    if (scan.unknown) return .{ .unknown = "Z030 structured shape unsupported or budget exhausted" };
    if (scan.warning) |warning| return .{ .warning = warning };
    if (remaining & 1 != 0) return .{ .warning = "deinit fallthrough lacks receiver poisoning or destroy shape" };
    return .accepted;
}
