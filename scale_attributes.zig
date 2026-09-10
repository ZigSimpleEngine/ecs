const std = @import("std");
const builtin = @import("builtin");
const ecs_module = @import("src/ecs.zig");

const Pos = struct { x: f32 = 0, y: f32 = 0 };
const Buff = struct { amount: u32 = 0 };

const EcsA = ecs_module.ECS(.{.{Pos}});

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

fn spawnFlat(allocator: std.mem.Allocator, n: u32) !void {
    const S = struct {
        const S = @This();
        var count: u32 = 0;
        fn spawn(h: *EcsA.SystemHandler) anyerror!void {
            _ = try h.cmdCreateN(&[_]type{Pos}, .{Pos{}}, S.count);
        }
    };
    S.count = n;
    try EcsA.Schedule(.{S.spawn}).run(allocator);
}

fn wipeWorld(comptime E: type, allocator: std.mem.Allocator) !void {
    const S = struct {
        fn wipe(h: *E.SystemHandler) anyerror!void {
            try h.cmdDestroyPages(&[_]type{Pos}, null);
        }
    };
    try E.Schedule(.{S.wipe}).run(allocator);
}

/// Emit one attribute per entity via per-entity loop. Times queue + flush.
fn benchAttrEmit(allocator: std.mem.Allocator, n: usize) !struct { emit_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var want_n: usize = 0;
        var emit_ns: u64 = 0;
        fn emit(h: *EcsA.SystemHandler) anyerror!void {
            const t0 = stamp();
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetAttribute(e, Buff, .{ .amount = 1 });
                }
            }
            S.emit_ns = nsSince(t0);
        }
        fn check(h: *EcsA.SystemHandler) anyerror!void {
            var total: usize = 0;
            for (h.allAttributes(Buff)) |page| {
                total += page.count();
            }
            try std.testing.expect(total == S.want_n);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try EcsA.Schedule(.{ S.emit, S.check }).run(allocator);
    return .{ .emit_ns = S.emit_ns, .total_ns = nsSince(t0) };
}

/// Read every attribute via getAttribute (slot-map path).
fn benchAttrGet(allocator: std.mem.Allocator, n: usize) !struct { read_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var want_n: usize = 0;
        var read_ns: u64 = 0;
        fn emit(h: *EcsA.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetAttribute(e, Buff, .{ .amount = 2 });
                }
            }
        }
        fn read(h: *EcsA.SystemHandler) anyerror!void {
            const t0 = stamp();
            var sum: u64 = 0;
            var count: usize = 0;
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    sum += (try h.getAttribute(e, Buff)).amount;
                    count += 1;
                }
            }
            S.read_ns = nsSince(t0);
            try std.testing.expect(count == S.want_n);
            try std.testing.expect(sum == 2 * S.want_n);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try EcsA.Schedule(.{ S.emit, S.read }).run(allocator);
    return .{ .read_ns = S.read_ns, .total_ns = nsSince(t0) };
}

/// Destroy every attribute via entity-slice batch.
fn benchAttrDestroy(allocator: std.mem.Allocator, n: usize) !struct { wipe_ns: u64, total_ns: u64 } {
    const S = struct {
        const S = @This();
        var want_n: usize = 0;
        var wipe_ns: u64 = 0;
        fn emit(h: *EcsA.SystemHandler) anyerror!void {
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    try h.cmdSetAttribute(e, Buff, .{ .amount = 1 });
                }
            }
        }
        fn wipe(h: *EcsA.SystemHandler) anyerror!void {
            var refs: [100000]EcsA.EntityReference = undefined;
            var count: usize = 0;
            for (h.allAttributes(Buff)) |page| {
                for (page.entityList()) |e| {
                    refs[count] = e;
                    count += 1;
                }
            }
            try std.testing.expect(count == S.want_n);
            const t0 = stamp();
            try h.cmdDestroyAttributesFor(refs[0..count], Buff);
            S.wipe_ns = nsSince(t0);
        }
    };
    S.want_n = n;
    const t0 = stamp();
    try EcsA.Schedule(.{ S.emit, S.wipe }).run(allocator);
    return .{ .wipe_ns = S.wipe_ns, .total_ns = nsSince(t0) };
}

test "bench S12a: attribute emit ladder (single page)" {
    const allocator = std.testing.allocator;
    defer EcsA.deinit(allocator);
    for (Ns) |n| {
        try spawnFlat(allocator, @intCast(n));
        var cold_emit: u64 = 0;
        var best_emit: u64 = std.math.maxInt(u64);
        var cold_frame: u64 = 0;
        var best_frame: u64 = std.math.maxInt(u64);
        for (0..REPS) |r| {
            const m = try benchAttrEmit(allocator, n);
            if (r == 0) {
                cold_emit = m.emit_ns;
                cold_frame = m.total_ns;
            }
            best_emit = @min(best_emit, m.emit_ns);
            best_frame = @min(best_frame, m.total_ns);
        }
        std.debug.print("S12a attr-emit 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_emit), ms(best_emit), ms(cold_frame), ms(best_frame) });
        try wipeWorld(EcsA, allocator);
    }
}

test "bench S12b/c: attribute get and destroy at max N (single page)" {
    const allocator = std.testing.allocator;
    defer EcsA.deinit(allocator);
    const n = Ns[Ns.len - 1];
    try spawnFlat(allocator, @intCast(n));
    var cold_read: u64 = 0;
    var best_read: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchAttrGet(allocator, n);
        if (r == 0) {
            cold_read = m.read_ns;
        }
        best_read = @min(best_read, m.read_ns);
    }
    std.debug.print("S12b attr-get 1-page N={d}: read cold {d:.3} / best {d:.3} ms\n", .{ n, ms(cold_read), ms(best_read) });
    var cold_wipe: u64 = 0;
    var best_wipe: u64 = std.math.maxInt(u64);
    var cold_wframe: u64 = 0;
    var best_wframe: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const m = try benchAttrDestroy(allocator, n);
        if (r == 0) {
            cold_wipe = m.wipe_ns;
            cold_wframe = m.total_ns;
        }
        best_wipe = @min(best_wipe, m.wipe_ns);
        best_wframe = @min(best_wframe, m.total_ns);
    }
    std.debug.print("S12c attr-destroy-for 1-page N={d}: queue cold {d:.2} / best {d:.2} ms, frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_wipe), ms(best_wipe), ms(cold_wframe), ms(best_wframe) });
}

test "bench S12d: reparent zone moves at max N (one subtree)" {
    const allocator = std.testing.allocator;
    defer EcsA.deinit(allocator);
    const n = Ns[Ns.len - 1];
    const S = struct {
        const S = @This();
        var root: EcsA.EntityReference = undefined;
        var target: EcsA.EntityReference = undefined;
        var count: u32 = 0;
        var attached: bool = false;
        fn build(h: *EcsA.SystemHandler) anyerror!void {
            S.root = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            S.target = try h.cmdCreate(&[_]type{Pos}, .{Pos{}});
            _ = try h.cmdCreateChildren(S.root, &[_]type{Pos}, .{Pos{}}, S.count);
        }
        fn emit_attrs(h: *EcsA.SystemHandler) anyerror!void {
            // O(N) probe per entity via the slot map; only missing ones queue.
            for (h.pages(&[_]type{Pos}, null).nonEmptyPages()) |page| {
                for (page.entities()) |e| {
                    if (h.getAttribute(e, Buff)) |_| {
                    } else |_| {
                        try h.cmdSetAttribute(e, Buff, .{ .amount = 1 });
                    }
                }
            }
        }
        fn toggle(h: *EcsA.SystemHandler) anyerror!void {
            // Alternate attach/detach so every rep moves the whole subtree.
            if (S.attached) {
                try h.cmdReparent(S.root, null);
            } else {
                try h.cmdReparent(S.root, S.target);
            }
            S.attached = !S.attached;
        }
        fn verify(h: *EcsA.SystemHandler) anyerror!void {
            // Zones tile the rows without gaps; every row keeps its value.
            const pages = h.allAttributes(Buff);
            try std.testing.expect(pages.len == 1);
            const page = &pages[0];
            try std.testing.expect(page.count() == S.count + 2);
            var covered: u32 = 0;
            var prev_end: u32 = 0;
            for (page.depthZones()) |z| {
                try std.testing.expect(z.offset == prev_end);
                covered += z.len;
                prev_end = z.offset + z.len;
            }
            try std.testing.expect(covered == page.count());
            var sum: u64 = 0;
            for (page.attributeList()) |a| {
                sum += a.amount;
            }
            try std.testing.expect(sum == S.count + 2);
        }
    };
    S.count = @intCast(n);
    S.attached = false;
    const t_build = stamp();
    try EcsA.Schedule(.{ S.build, S.emit_attrs }).run(allocator);
    std.debug.print("S12d build 1-page N={d}: {d:.2} ms\n", .{ n, ms(nsSince(t_build)) });
    var cold_frame: u64 = 0;
    var best_frame: u64 = std.math.maxInt(u64);
    for (0..REPS) |r| {
        const t0 = stamp();
        try EcsA.Schedule(.{S.toggle}).run(allocator);
        const dt = nsSince(t0);
        if (r == 0) {
            cold_frame = dt;
        }
        best_frame = @min(best_frame, dt);
    }
    std.debug.print("S12d reparent-subtree 1-page N={d}: frame cold {d:.2} / best {d:.2} ms\n", .{ n, ms(cold_frame), ms(best_frame) });
    try EcsA.Schedule(.{S.verify}).run(allocator);
    try wipeWorld(EcsA, allocator);
}
