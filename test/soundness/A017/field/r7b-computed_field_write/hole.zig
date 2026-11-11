// A017: the state written in a second function through an inline for over the holder's field names (@field, a comptime name)
const Phase = enum { idle, running, done };
pub const Job = struct {
    phase: Phase = .idle,
    count: u32 = 0,
    pub fn reset(j: *Job) void {
        const info = @typeInfo(Job).@"struct";
        inline for (info.field_names, info.field_types, info.field_attrs) |name, T, attrs| {
            @field(j, name) = attrs.defaultValue(T).?;
        }
    }
    pub fn step(j: *Job) void {
        switch (j.phase) {
            .idle => j.phase = .running,
            .running => j.phase = .done,
            .done => {},
        }
    }
};
