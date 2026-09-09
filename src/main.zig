const std = @import("std");
const Transform = .{ Position, Scale };
const Player = .{ Transform, Scale, Health };
const ECS = @import("ecs.zig").ECS(.{
    Transform,
    .{Player},
    .{Enemy},
    .{ Player, Enemy },
    .{ Player, Empty1 },
    .{ Player, Empty2 },
    .{ Player, Empty3 },
    .{ Player, Empty4 },
    .{ Player, Empty5 },
    .{ Player, Empty1, Empty2 },
    .{ Player, Empty1, Empty2, Empty3 },
});

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Scale = struct { w: f32 = 0, h: f32 = 0 };
const Health = struct { value: f32 = 0 };
const Enemy = struct {};
const Empty1 = struct {};
const Empty2 = struct {};
const Empty3 = struct {};
const Empty4 = struct {};
const Empty5 = struct {};
const CustomEvent = struct {};

const App = ECS.Schedule(.{ setup, print, printAllVsNonempty });
var player1: ECS.EntityReference = undefined;
fn setup(h: *ECS.SystemHandler) anyerror!void {
    player1 = try h.cmdCreate(Player, .{
        Position{ .x = 10, .y = -3 },
        Scale{ .w = 1, .h = 1 },
        Health{ .value = 100 },
    });
    try h.cmdSetEvent(player1, CustomEvent, .{});
    std.log.debug("Is player 1 alive: {}", .{player1.isAlive()});
    const player2 = try h.cmdCreateChild(player1, .{ Player, Enemy }, .{
        Position{ .x = 55, .y = 2 },
        Scale{ .w = 2, .h = 2 },
        Health{ .value = 50 },
        Enemy{},
    });
    const enemy1 = try h.cmdCreateChild(player1, Enemy, .{Enemy{}});
    try h.cmdSetEvent(enemy1, CustomEvent, .{});

    try h.cmdSetEvent(player2, CustomEvent, .{});
}

fn sumEvents(comptime T: type, pages: []const ECS.EventPage(T)) usize {
    var events_sum: usize = 0;
    for (pages) |ep| {
        for (ep.entityList()) |e| {
            if (e.isAlive()) {
                events_sum += 1;
            }
        }
    }
    return events_sum;
}

fn print(h: *ECS.SystemHandler) anyerror!void {
    // for (h.filterEvents(CustomEvent, .{Enemy}, .{})) |e| {
    //     try h.cmdDestroy(e.entityAt(0));
    //     std.debug.print("Destroying CustomEvent, Enemy: {any}\n", .{e.entityAt(0)});
    //     break;
    // }
    std.debug.print("Is player 1 alive: {}\n", .{player1.isAlive()});
    for (h.pages(.{Position}, null).nonEmptyPages()) |p| {
        for (p.depthZones()) |d| {
            for (p.get(Position), d.offset..d.len) |value, _| {
                std.debug.print("Pos: {any}\n", .{value});
            }

            for (p.entities()) |e| {
                std.debug.print("Parent: {any}\n", .{e.parent()});
            }
        }
    }
    const player2 = h.pages(.{ Enemy, Position }, .{}).nonEmptyPages()[0].entities()[0];
    const enemy1 = h.pages(.{Enemy}, .{Position}).nonEmptyPages()[0].entities()[0];
    try h.cmdReparent(enemy1, player2);

    for (h.filterEvents(CustomEvent, .{Health}, .{Enemy})) |p| {
        for (p.entityList()) |e| {
            std.debug.print("Enabled entity: {any}\n", .{e});
        }
    }

    std.debug.print("Custom events sum before: {}\n", .{sumEvents(CustomEvent, h.allEvents(CustomEvent))});
}

fn printAllVsNonempty(h: *ECS.SystemHandler) !void {
    const nonempty_len = h.pages(.{Position}, null).nonEmptyPages().len;
    const pages_container = h.pages(.{Position}, null);
    const all_len = pages_container.allPages().len;
    std.debug.print("All: {}; Nonempty: {}\n", .{ all_len, nonempty_len });

    std.debug.print("Custom events sum after: {}\n", .{sumEvents(CustomEvent, h.allEvents(CustomEvent))});
    std.debug.print("Reparent events sum: {}\n", .{sumEvents(ECS.Reparent, h.allEvents(ECS.Reparent))});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    defer ECS.deinit(gpa);
    //
    std.debug.print("Id: {}\n", .{ECS.archetypeId(.{ Position, Scale, Health })});

    try App.run(gpa);
}
