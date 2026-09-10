const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Position = struct { x: f32 = 0, y: f32 = 0 };
const MoveSpeed = struct { mult: f32 = 1 };
const Move = struct { dx: f32 = 0, dy: f32 = 0 };

const Ecs = ecs_module.ECS(.{.{ Position, MoveSpeed }});

const N_ENTITIES: u32 = 100_000;
const REPS: usize = if (builtin.mode == .Debug) 2 else 3;

// Single offset applied to every entity by the direct pass.
const CDX: f32 = 2.0;
const CDY: f32 = -1.0;

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
fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

test "indirection: scattered event-driven vs sequential page pass" {
    const allocator = std.testing.allocator;
    defer Ecs.deinit(allocator);
    const S = struct {
        const S = @This();
        // Percent of entities (0..100) receiving a Move event this rep.
        var pct: u32 = 0;
        var rng_state: u64 = 0;
        // Event count of the current rep; drives the direct pass length.
        var emitted: usize = 0;
        var consumed: usize = 0;
        var events_ns: u64 = 0;
        var direct_ns: u64 = 0;
        var sum_ev: f64 = 0;
        var sum_direct: f64 = 0;
        fn spawn(h: *Ecs.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{ Position, MoveSpeed }, .{ Position{}, MoveSpeed{} }, N_ENTITIES);
        }
        fn emit(h: *Ecs.SystemHandler) anyerror!void {
            S.emitted = 0;
            S.consumed = 0;
            S.sum_ev = 0;
            S.sum_direct = 0;
            var prng = std.Random.DefaultPrng.init(S.rng_state);
            const rng = prng.random();
            for (h.pages(&[_]type{ Position, MoveSpeed }, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    if (rng.int(u32) % 100 < S.pct) {
                        const dx = (rng.float(f32) - 0.5) * 10.0;
                        const dy = (rng.float(f32) - 0.5) * 10.0;
                        try h.cmdSetEvent(e, Move, .{ .dx = dx, .dy = dy });
                        S.emitted += 1;
                    }
                }
            }
        }
        fn apply_events(h: *Ecs.SystemHandler) anyerror!void {
            const t0 = stamp();
            var n: usize = 0;
            var s: f64 = 0;
            for (h.allEvents(Move)) |page| {
                for (0..page.count()) |i| {
                    const e = page.entityAt(i);
                    const mv = page.valueAt(i);
                    const speed = try h.getComponent(e, MoveSpeed);
                    const pos = try h.getComponent(e, Position);
                    pos.x += mv.dx * speed.mult;
                    pos.y += mv.dy * speed.mult;
                    s += @as(f64, pos.x + pos.y);
                    n += 1;
                }
            }
            S.events_ns = nsSince(t0);
            S.consumed = n;
            S.sum_ev = s;
            try std.testing.expect(n == S.emitted);
        }
        fn apply_direct(h: *Ecs.SystemHandler) anyerror!void {
            const t0 = stamp();
            var s: f64 = 0;
            var done: usize = 0;
            for (h.pages(&[_]type{ Position, MoveSpeed }, null).nonEmptyPages()) |page| {
                if (done >= S.emitted) {
                    break;
                }
                const poss = page.get(Position);
                const speeds = page.get(MoveSpeed);
                const take = @min(S.emitted - done, poss.len);
                for (poss[0..take], speeds[0..take]) |*p, spd| {
                    p.x += CDX * spd.mult;
                    p.y += CDY * spd.mult;
                    s += @as(f64, p.x + p.y);
                }
                done += take;
            }
            S.direct_ns = nsSince(t0);
            S.sum_direct = s;
            try std.testing.expect(done == S.emitted);
        }
    };
    try Ecs.Schedule(.{S.spawn}).run(allocator);
    for (0..REPS) |rep| {
        S.rng_state = 12345 + @as(u64, @intCast(rep)) * 999983;
        var ps = std.Random.DefaultPrng.init(S.rng_state ^ 0x12345);
        S.pct = ps.random().int(u32) % 101;
        try Ecs.Schedule(.{ S.emit, S.apply_events, S.apply_direct }).run(allocator);
        const ratio = @as(f64, @floatFromInt(S.events_ns)) / @as(f64, @floatFromInt(S.direct_ns));
        std.debug.print("rep {d}: pct={d} M={d} events {d:.2} ms, direct {d:.2} ms, ratio {d:.2}x sum_ev={d:.1} sum_direct={d:.1}\n", .{
            rep,
            S.pct,
            S.emitted,
            ms(S.events_ns),
            ms(S.direct_ns),
            ratio,
            S.sum_ev,
            S.sum_direct,
        });
    }
}
