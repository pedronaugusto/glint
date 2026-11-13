// A001: @bitCast builds a governed id from an integer without its API (review 8, M5).
const std = @import("std");
const aegis = @import("aegis");
const Id = aegis.id.Id(struct {}, u32);
pub fn f(raw: u32) Id {
    return @bitCast(raw);
}
