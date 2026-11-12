// matrix: a public callback's signature takes two u32 ids
pub const Hooks = struct {
    linked: *const fn (parent_id: u32, child_id: u32) void,
};
