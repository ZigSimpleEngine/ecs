const std = @import("std");
const Transform = .{ Position, Scale };
const Player = .{ Transform, Scale, Health };
const ECS = @import("ecs.zig").ECS(.{
    Transform,
    .{Player},
    .{ Player, Enemy },
});

const Position = struct { x: f32 = 0, y: f32 = 0 };
const Scale = struct { w: f32 = 0, h: f32 = 0 };
const Health = struct { value: f32 = 0 };
const Enemy = struct {};

const App = ECS.Schedule(.{ setup, print });

fn setup(h: *ECS.SystemHandler) anyerror!void {
    try h.cmdCreate(Player, .{
        Position{ .x = 10, .y = -3 },
        Scale{ .w = 1, .h = 1 },
        Health{ .value = 100 },
    });
    try h.cmdCreate(.{ Player, Enemy }, .{
        Position{ .x = 55, .y = 2 },
        Scale{ .w = 2, .h = 2 },
        Health{ .value = 50 },
        Enemy{},
    });
}

fn print(h: *ECS.SystemHandler) anyerror!void {
    var it = h.pages(.{Position}, .{Enemy});
    while (it.next()) |p| {
        for (p.get(Position)) |value| {
            std.debug.print("Pos: {any}\n", .{value});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    defer ECS.deinit(gpa);

    std.debug.print("Id: {}\n", .{ECS.archetypeId(.{ Position, Scale, Health })});

    try App.run(gpa);
}
