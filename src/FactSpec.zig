//! What a rule declares of a flow fact it asks (`RuleContext.Rule.facts`), as data `Taint`
//! solves: where it starts, what answers it, whether what it decides takes it, and the sinks
//! the rule judges at which level. It imports nothing of glint's, so a rule's contract can
//! name it.

/// How far a value is input's, each level holding the ones below it: clean; unknown, through a
/// call that does not resolve; data, bytes from outside; a number a peer chooses.
pub const Level = enum(u2) {
    clean,
    unknown,
    data,
    number,

    pub fn join(a: Level, b: Level) Level {
        return if (@backingInt(a) >= @backingInt(b)) a else b; // safe: two-bit levels.
    }
    /// Whether the value is input at `least` (data or number).
    pub fn reaches(a: Level, least: Level) bool {
        return a != .unknown and @backingInt(a) >= @backingInt(least); // safe: two-bit levels.
    }
};

/// A fact a rule asks of the program's values, as data: where it starts, what answers it,
/// whether what it decides takes it, and the sinks the rule judges. A rule declares the specs
/// it asks (`RuleContext.Rule.facts`); one solve reads them all, a lane each (`Taint.Levels`).
pub const Spec = struct {
    source: Source,
    /// Whether a value a condition the fact reaches chooses takes the fact: what a branch, a
    /// loop's passes or a jump past a store decides (implicit flow), and a comparison's truth.
    control: bool,
    answers: Answers = .{},
    sinks: Sinks = .{},
    /// The least level a sink site reaches the sink at (`Taint.SinkSite.verdict`).
    reaches: Level = .data,
};

pub const Source = union(enum) {
    /// What comes from outside the program: a peer's (what a reader, a file's contents, a
    /// child's output or an archive give) or the operator's (the process's arguments and
    /// environment, and what std's start code hands the root `main`).
    input: Provenance,
    /// The text of an error: an error value, a capture of one, and its name.
    error_text,
    /// A writer whose bytes reach a peer: what `net.Stream.writer` gives, and the functions the
    /// configuration declares write to one.
    peer_writer,
};

pub const Provenance = packed struct(u2) { peer: bool, operator: bool };

/// What clears the fact. `aegis`: aegis's answer to it, the refinement `input.Untrusted.parse`
/// makes of input and the text aegis gives an error. `int_from_error`: an error's integer is no
/// text.
pub const Answers = packed struct(u2) { aegis: bool = false, int_from_error: bool = false };

/// The sinks Taint finds for a rule (`Taint.sinkSites`): the sizes the program hands outside it, and
/// the values written to a peer.
pub const Sinks = packed struct(u2) { size: bool = false, peer_write: bool = false };
