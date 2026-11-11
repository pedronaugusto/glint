// D001: a private var whose name is spelled only inside its own initializer
const Node = struct { next: *const Node };
var node: Node = .{ .next = &node };
pub const one = 1;
