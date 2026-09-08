const std = @import("std");
const Transform = .{ Position, Scale };
const Player = .{ Transform, Scale, Health };
const ECS = @import("ecs.zig").ECS(.{
    Transform,
    .{Player},
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

const App = ECS.Schedule(.{ setup, print, print_all_vs_nonempty });
var player1: ECS.EntityReference = undefined;
fn setup(h: *ECS.SystemHandler) anyerror!void {
    player1 = try h.cmdCreate(Player, .{
        Position{ .x = 10, .y = -3 },
        Scale{ .w = 1, .h = 1 },
        Health{ .value = 100 },
    });
    std.log.debug("Is player 1 alive: {}", .{player1.isAlive()});
    _ = try h.cmdCreateChild(player1, .{ Player, Enemy }, .{
        Position{ .x = 55, .y = 2 },
        Scale{ .w = 2, .h = 2 },
        Health{ .value = 50 },
        Enemy{},
    });
}

fn print(h: *ECS.SystemHandler) anyerror!void {
    std.debug.print("Is player 1 alive: {}\n", .{player1.isAlive()});
    for (h.pages(.{Position}, null).nonEmptyPages()) |p| {
        for (p.get(Position)) |value| {
            std.debug.print("Pos: {any}\n", .{value});
        }

        for (p.entities()) |e| {
            std.debug.print("Parent: {any}\n", .{e.parent()});
        }
    }
}

fn print_all_vs_nonempty(h: *ECS.SystemHandler) !void {
    const nonempty_len = h.pages(.{Position}, null).nonEmptyPages().len;
    const pages_container = h.pages(.{Position}, null);
    const all_len = pages_container.allPages().len;
    std.debug.print("All: {}; Nonempty: {}\n", .{ all_len, nonempty_len });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    defer ECS.deinit(gpa);
    //
    std.debug.print("Id: {}\n", .{ECS.archetypeId(.{ Position, Scale, Health })});

    try App.run(gpa);
}
