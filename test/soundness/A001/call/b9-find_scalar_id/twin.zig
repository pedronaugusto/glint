// A001: an id looked up in a slice by std's findScalar, which compares with ==, as the id's enum allows.
const aegis = @import("aegis");
const std = @import("std");
const ImageId = aegis.id.Id(enum { image }, u32);
pub fn has(ids: []const ImageId, id: ImageId) bool {
    return std.mem.findScalar(ImageId, ids, id) != null;
}
