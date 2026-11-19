// P007 twin: the interface idiom, @alignCast(@fieldParentPtr(...)), which P007 does not read
const Node = struct { value: u32, link: u32 };
pub fn owner(link: *u32) *Node {
    return @alignCast(@fieldParentPtr("link", link));
}
