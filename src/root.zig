const ecs_module = @import("ecs.zig");

pub const ECS = ecs_module.ECS;
pub const ReadOnlyList = ecs_module.ReadOnlyList;

test {
    _ = ecs_module;
}
