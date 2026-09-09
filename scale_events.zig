const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };
const T0 = struct {};
const T1 = struct {};
const Damage = struct { amount: u32 = 0 };

// Single archetype: worst case, all events land in one page.
const Ecs1 = ecs_module.ECS(.{.{Pos}});
// Four archetypes: spread case, events split over four pages.
const Ecs4 = ecs_module.ECS(.{
    .{Pos},
    .{ Pos, T0 },
    .{ Pos, T1 },
    .{ Pos, T0, T1 },
});

// Smaller ladder in Debug: quadratic passes are ~30x slower there.
const Ns: []const usize = if (builtin.mode == .Debug)
    &.{ 500, 1000, 2000 }
else
    &.{ 1000, 2500, 5000, 10000 };

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// Monotonic bench clock via the global single-threaded Io backend.
/// No threads are spawned; resolution is platform-provided.
fn benchIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
fn stamp() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(benchIo(), .awake);
}
fn nsSince(t0: std.Io.Clock.Timestamp) u64 {
    const d = t0.durationTo(stamp());
    return @intCast(d.raw.toNanoseconds());
}

fn spawn1(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs1.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
        }
    };
    S.count = n;
    try Ecs1.Schedule(.{S.spawn}).run(allocator);
}

fn spawn4(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs4.SystemHandler) anyerror!void {
            const q: u32 = S.count / 4;
            const r: u32 = S.count - q * 4;
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, q + r);
            _ = try h.cmdCreateN(&[_]type{ Pos, T0 }, .{ Pos{}, T0{} }, q);
            _ = try h.cmdCreateN(&[_]type{ Pos, T1 }, .{ Pos{}, T1{} }, q);
            _ = try h.cmdCreateN(&[_]type{ Pos, T0, T1 }, .{ Pos{}, T0{}, T1{} }, q);
        }
    };
    S.count = n;
    try Ecs4.Schedule(.{S.spawn}).run(allocator);
}

fn countEvents(comptime E: type, allocator: std.mem.Allocator) usize {
    const handler = E.SystemHandler{ .allocator = allocator };
    var total: usize = 0;
    for (handler.allEvents(Damage)) |page| {
        total += page.count();
    }
    return total;
}

fn wipeWorld(comptime E: type, allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *E.SystemHandler) anyerror!void {
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try E.Schedule(.{S.wipe}).run(allocator);
}

/// One frame { emit, check }: emit is timed inline (queueSet path),
/// total covers queue + flush upsert + check + frame-end clear.
/// flush ~= total - emit (check is one linear pass).
fn benchEmit(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { emit_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var emit_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
            S.emit_ns = nsSince(t0);
        }
        fn check(h: *E.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_count);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.check }).run(allocator);
    return .{ .emit_ns = S.emit_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, read }: read is timed inline and verifies payloads.
/// read ~= pure consume cost (linear).
fn benchRead(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { read_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var read_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 3 });
                }
            }
        }
        fn read(h: *E.SystemHandler) anyerror!void {
            const t0 = stamp();
            var n: usize = 0;
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                n += page.count();
                for (page.eventList()) |ev| {
                    sum += ev.amount;
                }
            }
            S.read_ns = nsSince(t0);
            try std.testing.expect(n == S.want_count);
            try std.testing.expect(sum == 3 * S.want_count);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.read }).run(allocator);
    return .{ .read_ns = S.read_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, wipe }: wipe times queueDestroy per handle (findByEntity
/// path); flush remove cost lands in total (total - emit - wipe ~= remove).
fn benchDestroyEach(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var wipe_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
        }
        fn wipe(h: *E.SystemHandler) anyerror!void {
            const seen = blk: {
                var n: usize = 0;
                for (h.allEvents(Damage)) |page| {
                    n += page.count();
                }
                break :blk n;
            };
            try std.testing.expect(seen == S.want_count);
            const t0 = stamp();
            for (h.allEvents(Damage)) |page| {
                for (0..page.count()) |i| {
                    try h.cmdDestroyEvent(page.handleAt(i));
                }
            }
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

/// One frame { emit, kill }: kill queues entity destroys (cheap); the event
/// purge runs in flush, so purge ~= total - emit - kill.
fn benchPurge(comptime E: type, allocator: std.mem.Allocator, want: usize) !struct { kill_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var kill_ns: u64 = 0;
        var want_count: usize = 0;
        fn emit(h: *E.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 1 });
                }
            }
        }
        fn kill(h: *E.SystemHandler) anyerror!void {
            try std.testing.expect(countEvents(E, h.allocator) == S.want_count);
            const t0 = stamp();
            try h.cmdDestroyPages(&[_]type{Pos}, null);
            S.kill_ns = nsSince(t0);
        }
    };
    S.want_count = want;
    const t0 = stamp();
    try E.Schedule(.{ S.emit, S.kill }).run(allocator);
    return .{ .kill_ns = S.kill_ns, .total_ns = nsSince(t0) };
}

const MAXN: usize = 10000;
var bench_refs: [MAXN]Ecs1.EntityReference = undefined;

fn spawn1refs(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *Ecs1.SystemHandler) anyerror!void {
            const created = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
            for (created, 0..) |ref, i| {
                bench_refs[i] = ref;
            }
        }
    };
    S.count = n;
    try Ecs1.Schedule(.{S.spawn}).run(allocator);
}

/// S7: one cmdSetEvents call for all entities. Compares against S1's
/// per-entity loop (validate-once + single reservation vs N appends).
fn benchBatchSet(allocator: std.mem.Allocator, n: usize) !struct { emit_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var emit_ns: u64 = 0;
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            try h.cmdSetEvents(bench_refs[0..want_n], Damage, .{ .amount = 4 });
            S.emit_ns = nsSince(t0);
        }
        fn check(h: *Ecs1.SystemHandler) anyerror!void {
            var total: usize = 0;
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
                for (page.eventList()) |ev| {
                    sum += ev.amount;
                }
            }
            try std.testing.expect(total == S.want_n);
            try std.testing.expect(sum == 4 * S.want_n);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.check }).run(allocator);
    return .{ .emit_ns = S.emit_ns, .total_ns = nsSince(t0) };
}

/// S8: one cmdDestroyEventsFor call for all entities. Compares against S3's
/// per-handle loop.
fn benchBatchDestroy(allocator: std.mem.Allocator, n: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var wipe_ns: u64 = 0;
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            try h.cmdSetEvents(bench_refs[0..want_n], Damage, .{ .amount = 1 });
        }
        fn wipe(h: *Ecs1.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allEvents(Damage)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_n);
            const t0 = stamp();
            try h.cmdDestroyEventsFor(bench_refs[0..want_n], Damage);
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

test "bench S1: emit ladder (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    for (Ns) |n| {
        try spawn1(allocator, @intCast(n));
        const r = try benchEmit(Ecs1, allocator, n);
        std.debug.print("S1 emit 1-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(r.emit_ns), ms(r.total_ns) });
        try std.testing.expect(countEvents(Ecs1, allocator) == 0); // frame-end clear
        try wipeWorld(Ecs1, allocator);
    }
}

test "bench S2/S3: read and destroy-each at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    const r = try benchRead(Ecs1, allocator, n);
    std.debug.print("S2 read 1-page N={d}: read {d:.3} ms, frame {d:.2} ms\n", .{ n, ms(r.read_ns), ms(r.total_ns) });
    const w = try benchDestroyEach(Ecs1, allocator, n);
    std.debug.print("S3 destroy-each 1-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(w.wipe_ns), ms(w.total_ns) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S4: spread over 4 pages at max N" {
    const allocator = std.testing.allocator;
    defer Ecs4.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn4(allocator, @intCast(n));
    const e = try benchEmit(Ecs4, allocator, n);
    std.debug.print("S1 emit 4-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(e.emit_ns), ms(e.total_ns) });
    const r = try benchRead(Ecs4, allocator, n);
    std.debug.print("S2 read 4-page N={d}: read {d:.3} ms, frame {d:.2} ms\n", .{ n, ms(r.read_ns), ms(r.total_ns) });
    const w = try benchDestroyEach(Ecs4, allocator, n);
    std.debug.print("S3 destroy-each 4-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(w.wipe_ns), ms(w.total_ns) });
    try std.testing.expect(countEvents(Ecs4, allocator) == 0);
}

test "bench S5: full frame emit+consume+destroy (single page, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    const S = struct {
        const S = @This();
        var want_n: usize = 0;
        fn emit(h: *Ecs1.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetEvent(e, Damage, .{ .amount = 2 });
                }
            }
        }
        fn consume(h: *Ecs1.SystemHandler) anyerror!void {
            var sum: u64 = 0;
            for (h.allEvents(Damage)) |page| {
                for (0..page.count()) |i| {
                    sum += page.valueAt(i).amount;
                    try h.cmdDestroyEvent(page.handleAt(i));
                }
            }
            try std.testing.expect(sum == 2 * S.want_n);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try Ecs1.Schedule(.{ S.emit, S.consume }).run(allocator);
    std.debug.print("S5 full frame 1-page N={d}: {d:.2} ms\n", .{ n, ms(nsSince(t0)) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S6b: destroy entities WITHOUT events (baseline, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    const S = struct {
        const S = @This();
        var kill_ns: u64 = 0;
        fn kill(h: *Ecs1.SystemHandler) anyerror!void {
            const t0 = stamp();
            try h.cmdDestroyPages(&[_]type{Pos}, null);
            S.kill_ns = nsSince(t0);
        }
    };
    const t0 = stamp();
    try Ecs1.Schedule(.{S.kill}).run(allocator);
    std.debug.print("S6b destroy-no-events 1-page N={d}: kill-queue {d:.3} ms, frame {d:.2} ms\n", .{ n, ms(S.kill_ns), ms(nsSince(t0)) });
}

test "bench S6: destroy entities carrying events (purge path, max N)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1(allocator, @intCast(n));
    const r = try benchPurge(Ecs1, allocator, n);
    std.debug.print("S6 purge 1-page N={d}: kill-queue {d:.3} ms, frame {d:.2} ms\n", .{ n, ms(r.kill_ns), ms(r.total_ns) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}

test "bench S7/S8: batch set and destroy-for at max N (single page)" {
    const allocator = std.testing.allocator;
    defer Ecs1.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawn1refs(allocator, @intCast(n));
    const s = try benchBatchSet(allocator, n);
    std.debug.print("S7 batch-set 1-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(s.emit_ns), ms(s.total_ns) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
    const w = try benchBatchDestroy(allocator, n);
    std.debug.print("S8 batch-destroy-for 1-page N={d}: queue {d:.2} ms, frame {d:.2} ms\n", .{ n, ms(w.wipe_ns), ms(w.total_ns) });
    try std.testing.expect(countEvents(Ecs1, allocator) == 0);
}
