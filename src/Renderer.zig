const Renderer = @This();

const std = @import("std");
const hy = @import("hyoga");
const Atlas = @import("Atlas.zig");
const SpritePass = @import("SpritePass.zig");

const vec2 = hy.math.vec2;
const Gpu = hy.Rt.Gpu;

time_scale: f32,
clear_color: hy.Color,
surface: hy.Rt.Surface,
gpa: std.mem.Allocator,
gpu: Gpu,
arena: std.heap.ArenaAllocator.State,
atlas: Atlas,
pass: SpritePass,
sprites: hy.DenseMap(Sprite),
target_texture: Gpu.Texture,
viewport_size: [2]u16,

pub const Sprite = struct {
    time: std.Io.Timestamp = .zero,
    tag: u32,
    position: vec2,
    sort_order: f32,

    pub const Handle = hy.DenseMap(Sprite).Handle;
};

pub const InitOptions = struct {
    clear_color: hy.Color = .black,
    viewport_size: [2]u16 = .{ 0, 0 },
    blob: hy.PackFile.Blob,
};

pub fn init(rt: hy.Rt, surface: hy.Rt.Surface, opts: InitOptions) !Renderer {
    const gpu: hy.Rt.Gpu = try .init(rt, .{ .surface = surface });
    errdefer gpu.deinit(rt);

    const surface_size = surface.size();

    const target_texture: Gpu.Texture = try .init(gpu, .{
        .name = "hyspr Target Texture",
        .usage = .{ .color_target = true, .sampler = true },
        .width = if (opts.viewport_size[0] != 0) opts.viewport_size[0] else surface_size[0],
        .height = if (opts.viewport_size[1] != 0) opts.viewport_size[1] else surface_size[1],
        .format = .swapchain(gpu),
    });

    const atlas: Atlas = try .init(rt.gpa, gpu, opts.blob);

    var sprite_pass: SpritePass = try .init(rt.gpa, gpu);
    errdefer sprite_pass.deinit(gpu);

    return .{
        .gpa = rt.gpa,
        .gpu = gpu,
        .arena = .init,
        .surface = surface,
        .target_texture = target_texture,
        .viewport_size = opts.viewport_size,
        .clear_color = opts.clear_color,
        .sprites = .empty,
        .time_scale = 1.0,
        .pass = sprite_pass,
        .atlas = atlas,
    };
}

pub fn deinit(r: *Renderer, rt: hy.Rt) void {
    r.target_texture.deinit(r.gpu);
    r.arena.promote(r.gpa).deinit();
    r.pass.deinit(r.gpu);
    r.atlas.deinit(r.gpa, r.gpu);
    r.sprites.deinit(r.gpa);
    r.gpu.deinit(rt);
}

pub fn add(r: *Renderer, name: []const u8) !Sprite.Handle {
    const tag = r.atlas.tags.get(name).?;
    const hdl = try r.sprites.insert(r.gpa, .{
        .tag = tag,
        .position = .zero,
        .sort_order = 0,
    });
    return hdl;
}

pub fn sprite_position_set(r: *Renderer, hdl: Sprite.Handle, position: vec2) void {
    r.sprites.get_ptr(hdl).?.position = position;
}

pub fn sprite_sort_order_set(r: *Renderer, hdl: Sprite.Handle, sort_order: f32) void {
    r.sprites.get_ptr(hdl).?.sort_order = sort_order;
}

pub fn update(r: *Renderer, delta_time: std.Io.Duration) !void {
    const scaled_time: std.Io.Duration = .fromNanoseconds(@trunc(@as(f64, @floatFromInt(delta_time.nanoseconds)) * r.time_scale));

    var arena_allocator = r.arena.promote(r.gpa);
    defer {
        _ = arena_allocator.reset(.retain_capacity);
        r.arena = arena_allocator.state;
    }

    const arena = arena_allocator.allocator();

    const p = hy.Rt.Gpu.Presentation.init(r.gpu, .no_wait) catch |err| switch (err) {
        error.SwapchainNotAvailable => return,
        else => return err,
    };

    const w, const h = if (r.viewport_size[0] == 0 or r.viewport_size[1] == 0)
        .{ p.screen.width, p.screen.height }
    else
        r.viewport_size;

    var camera: hy.Camera = .orthographic(.zero, .pz, 1.0, 1.0);
    camera.aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
    camera.projection.orthographic.size = @floatFromInt(h);
    camera.look_direction = .nz;

    r.pass.scene = .{
        .view = camera.view(),
        .projection = camera.proj(),
    };

    for (r.sprites.slice()) |*sprite| {
        sprite.time = sprite.time.addDuration(scaled_time);

        try r.pass.instance_add(r, arena, .{
            .position = sprite.position.append(0),
            .sprite = sprite.tag,
            .anim_time = sprite.time,
            .z_order = sprite.sort_order,
        });
    }

    try r.pass.prepare(r.gpu, p.cmd);

    const render_pass: hy.Rt.Gpu.RenderPass = try .init(r.gpu, p.cmd, .{
        .color_targets = &.{.{
            .clear_color = r.clear_color.asvec4_norm(),
            .texture = r.target_texture,
            .load_op = .clear,
            .store_op = .store,
        }},
    });

    r.pass.render(r, p.cmd, render_pass);

    render_pass.end(r.gpu);

    const upscale_y = p.screen.height / h;
    const upscale_x = p.screen.width / w;
    const upscale = @min(upscale_x, upscale_y);

    const x = (p.screen.width -| w * upscale) / 2;
    const y = (p.screen.height -| h * upscale) / 2;

    r.target_texture.blit(r.gpu, p.cmd, .{
        .dst = p.screen.texture,
        .src_area = .{ .w = w, .h = h },
        .dst_area = .{ .x = x, .y = y, .w = w * upscale, .h = h * upscale },
        .filter = .nearest,
    });

    try p.cmd.submit(r.gpu);
}
