// matrix A019 destructure: the interface pointer destructured into a local, then a copy of the interface installed: its function converts a pointer that is no Runner's field
const Sink = struct {
    report: *const fn (*Sink, u32) void,
};
const Context = struct {
    sink: *Sink,
    file: u32 = 0,
    fn at(c: *Context, n: u32) void {
        c.sink.report(c.sink, n);
    }
};
const Runner = struct {
    sink: Sink = .{ .report = report },
    count: u32 = 0,
    pub fn run(r: *Runner) void {
        var c: Context = .{ .sink = &r.sink };
        c.at(1);
        quiet(&c);
    }
};
fn report(sink: *Sink, n: u32) void {
    const runner: *Runner = @fieldParentPtr("sink", sink);
    runner.count += n;
}
fn quiet(c: *Context) void {
    const file, const saved = .{ c.file, c.sink };
    var copy = saved.*;
    c.sink = &copy;
    defer c.sink = saved;
    c.at(file);
}
