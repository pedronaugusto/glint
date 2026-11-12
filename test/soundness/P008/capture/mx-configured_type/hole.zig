// matrix: the ids' integer bound by an `if` capture of a configured optional type
const Config = struct { id: ?type = null };
const config: Config = .{ .id = u32 };
const Id = if (config.id) |T| T else usize;
pub fn link(parent_id: Id, child_id: Id) void {
    _ = parent_id;
    _ = child_id;
}
