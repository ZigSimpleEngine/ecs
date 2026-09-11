const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };

const EcsR = ecs_module.ECS(.{.{Pos}});

const Ns: []const usize = if (builtin.mode == .Debug)
    &.{ 500, 1000, 2000 }
else
    &.{ 10000, 25000, 50000, 100000 };

const REPS: usize = if (builtin.mode == .Debug) 2 else 3;

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

fn wipeWorld(allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *EcsR.SystemHandler) anyerror!void {
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try EcsR.Schedule(.{S.wipe}).run(allocator);
}

fn entityCount(allocator: std.mem.Allocator) usize {
    const handler = EcsR.SystemHandler{ .allocator = allocator };
    var total: usize = 0;
    for (handler.pages(&[_]type{Pos}, null).allPages()) |p| {
        total += p.entities().len;
    }
    return total;
}

/// R1: wide same-depth move. rootA/rootB + N children under rootA (depth 1),
/// then every child single cmdReparent to rootB (depth stays 1 -> delta==0
/// link-only fast path, but N separate linkChild tail appends + N commands).
fn benchWideMove(allocator: std.mem.Allocator, n: u32) !struct { queue_ns: u64, total_ns: u64, build_ms: f64 } {
    const S = struct {
        const S = @This();
        var root_a: EcsR.EntityReference = undefined;
        var root_b: EcsR.EntityReference = undefined;
        var count: u32 = 0;
        var queue_ns: u64 = 0;
        fn build(h: *EcsR.SystemHandler) anyerror!void {
            S.root_a = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            S.root_b = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            _ = try h.cmdCreateChildren(S.root_a, &[_]type{Pos}, .{Pos{}}, S.count);
        }
        fn move(h: *EcsR.SystemHandler) anyerror!void {
            const t0 = stamp();
            // Collect children of root_a (depth 1) and move them one by one.
            // Snapshot first: reparent mutates sibling links during flush only,
            // queue-time iteration over live pages is stable here.
            var kids: [100000]EcsR.EntityReference = undefined;
            var kcount: usize = 0;
            var it = S.root_a.children();
            while (it.next()) |kid| {
                kids[kcount] = kid;
                kcount += 1;
            }
            for (kids[0..kcount]) |kid| {
                try h.cmdReparent(kid, S.root_b);
            }
            S.queue_ns = nsSince(t0);
        }
        fn verify(h: *EcsR.SystemHandler) anyerror!void {
            _ = h;
            try std.testing.expect((try S.root_a.childCount()) == 0);
            try std.testing.expect((try S.root_b.childCount()) == S.count);
            try std.testing.expect(S.root_b.isAlive());
        }
    };
    S.count = n;
    const t_build = stamp();
    try EcsR.Schedule(.{S.build}).run(allocator);
    const build_ms = ms(nsSince(t_build));
    const t0 = stamp();
    try EcsR.Schedule(.{ S.move, S.verify }).run(allocator);
    return .{ .queue_ns = S.queue_ns, .total_ns = nsSince(t0), .build_ms = build_ms };
}

test "bench S15a: reparent-wide same-depth ladder (singles)" {
    const allocator = std.testing.allocator;
    defer EcsR.deinit(allocator);
    for (Ns) |n| {
        var cold_queue: u64 = 0;
        var best_queue: u64 = std.math.maxInt(u64);
        var cold_frame: u64 = 0;
        var best_frame: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            try wipeWorld(allocator);
            const m = try benchWideMove(allocator, @intCast(n));
            if (r == 0) {
                cold_queue = m.queue_ns;
                cold_frame = m.total_ns;
                std.debug.print("S15a wide-move N={d}: build {d:.2} ms\n", .{ n, m.build_ms });
            }
            best_queue = @min(best_queue, m.queue_ns);
            best_frame = @min(best_frame, m.total_ns);
            try std.testing.expect(entityCount(allocator) == n + 2);
        }
        std.debug.print("S15a wide-move N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_queue), ms(best_queue), ms(cold_frame), ms(best_frame) });
        try wipeWorld(allocator);
    }
}

// R2: whole-subtree depth shift. root + N children toggled attach/detach,
// every rep moves N+1 rows across depth zones with per-member
// removeRow+insertRowAtDepth cascade + DepthUpdate filing.
test "bench S15b: reparent-subtree depth shift at max N (singles)" {
    const allocator = std.testing.allocator;
    defer EcsR.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var root: EcsR.EntityReference = undefined;
        var target: EcsR.EntityReference = undefined;
        var count: u32 = 0;
        var attached: bool = false;
        fn build(h: *EcsR.SystemHandler) anyerror!void {
            S.root = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            _ = try h.cmdCreateChildren(S.root, &[_]type{Pos}, .{Pos{}}, S.count);
        }
        fn toggle(h: *EcsR.SystemHandler) anyerror!void {
            if (S.attached) {
                try h.cmdReparent(S.root, null);
            } else {
                try h.cmdReparent(S.root, S.target);
            }
            S.attached = !S.attached;
        }
        fn verify(h: *EcsR.SystemHandler) anyerror!void {
            _ = h;
            const want_depth: u32 = if (S.attached) 1 else 0;
            try std.testing.expect(try S.root.depthOf() == want_depth);
        }
    };
    S.count = @intCast(n);
    S.attached = false;
    const t_build = stamp();
    try EcsR.Schedule(.{S.build}).run(allocator);
    std.debug.print("S15b subtree N={d}: build {d:.2} ms\n", .{ n + 2, ms(nsSince(t_build)) });
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const t0 = stamp();
        try EcsR.Schedule(.{ S.toggle, S.verify }).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_frame = dt;
        }
        best_frame = @min(best_frame, dt);
    }
    std.debug.print("S15b subtree-shift N={d}: frame cold {d:.2} / best {d:.2} ms\n", .{ n + 2, ms(cold_frame), ms(best_frame) });
    try wipeWorld(allocator);
}

// S15c: deep-chain toggle, old vs new path in one binary. A single
// cmdReparent takes the legacy reparentById (per-row cascades across ~2048
// zones); cmdReparentMany with one root forces reparentBatch (depth writes
// plus one consolidate). Same workload, same verify.
test "bench S15c: reparent deep-chain single vs batch" {
    const allocator = std.testing.allocator;
    defer EcsR.deinit(allocator);
    const depth_links: u32 = if (builtin.mode == .Debug) 128 else 2048;
    const S = struct {
        const S = @This();
        var root: EcsR.EntityReference = undefined;
        var target: EcsR.EntityReference = undefined;
        var links: u32 = 0;
        var attached: bool = false;
        var use_batch: bool = false;
        fn build(h: *EcsR.SystemHandler) anyerror!void {
            S.root = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            var tip = S.root;
            var i: u32 = 0;
            while (i < S.links) : (i += 1) {
                tip = try h.cmdCreateChild(tip, &[_]type{Pos}, .{Pos{}});
            }
        }
        fn toggle(h: *EcsR.SystemHandler) anyerror!void {
            if (S.use_batch) {
                const list = [_]EcsR.EntityReference{S.root};
                if (S.attached) {
                    try h.cmdReparentMany(list[0..], null);
                } else {
                    try h.cmdReparentMany(list[0..], S.target);
                }
            } else {
                if (S.attached) {
                    try h.cmdReparent(S.root, null);
                } else {
                    try h.cmdReparent(S.root, S.target);
                }
            }
            S.attached = !S.attached;
        }
        fn verify(h: *EcsR.SystemHandler) anyerror!void {
            _ = h;
            const want: u32 = if (S.attached) 1 else 0;
            try std.testing.expect(try S.root.depthOf() == want);
        }
    };
    S.links = depth_links;
    inline for ([_]bool{ false, true }) |mode| {
        S.use_batch = mode;
        S.attached = false;
        try wipeWorld(allocator);
        try EcsR.Schedule(.{S.build}).run(allocator);
        var cold: u64 = 0;
        var best: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            const t0 = stamp();
            try EcsR.Schedule(.{ S.toggle, S.verify }).run(allocator);
            const dt = nsSince(t0);
            if (r == 0) {
                cold = dt;
            }
            best = @min(best, dt);
        }
        std.debug.print("S15c chain-toggle D={d} {s}: frame cold {d:.2} / best {d:.2} ms\n", .{
            depth_links + 2,
            if (mode) "batch" else "single",
            ms(cold),
            ms(best),
        });
    }
    try wipeWorld(allocator);
}
