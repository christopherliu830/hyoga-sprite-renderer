const Renderer = @This();

const std = @import("std");
const hy = @import("hyoga");
const hy_ui = @import("hy_ui");
const Atlas = @import("Atlas.zig");
const SpritePass = @import("SpritePass.zig");

const skb = hy_ui.Text.skb;
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
text: hy_ui.Text,
text_objects: hy.DenseMap(TextObject),
sprites: hy.DenseMap(Sprite),
target_texture: Gpu.Texture,
viewport_size: [2]u16,
camera_root_position: [3]u32,

pub const Sprite = struct {
    time: std.Io.Timestamp = .zero,
    tag: u32,
    position: vec2,
    sort_order: f32,
    time_scale: f32,
    scale: f32,
    rotation: f32,
    step: ?u32,
    flip_x: bool,

    pub const Handle = hy.DenseMap(Sprite).Handle;

    pub fn init(tag: u32) Sprite {
        return .{
            .tag = tag,
            .position = .zero,
            .sort_order = 0,
            .time_scale = 1.0,
            .scale = 1.0,
            .rotation = 0,
            .step = null,
            .flip_x = false,
        };
    }
};

pub const TextObject = struct {
    text: *skb.Text,
    layout: *skb.Layout,
    position: vec2,

    pub const Handle = hy.DenseMap(TextObject).Handle;
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

    var text: hy_ui.Text = try .init(rt.gpa, rt.io);
    errdefer text.deinit(gpu);

    return .{
        .gpa = rt.gpa,
        .gpu = gpu,
        .arena = .init,
        .surface = surface,
        .text = text,
        .text_objects = .empty,
        .target_texture = target_texture,
        .viewport_size = opts.viewport_size,
        .camera_root_position = .{ 0, 0, 0 },
        .clear_color = opts.clear_color,
        .sprites = .empty,
        .pass = sprite_pass,
        .atlas = atlas,
        .time_scale = 1.0,
    };
}

pub fn deinit(r: *Renderer, rt: hy.Rt) void {
    r.target_texture.deinit(r.gpu);
    r.arena.promote(r.gpa).deinit();
    r.pass.deinit(r.gpu);
    r.atlas.deinit(r.gpa, r.gpu);
    r.text_objects.deinit(r.gpa);
    r.sprites.deinit(r.gpa);
    r.gpu.deinit(rt);
}

pub fn add(r: *Renderer, name: []const u8) !Sprite.Handle {
    const tag = r.atlas.tags.get(name).?;
    const hdl = try r.sprites.insert(r.gpa, .init(tag));
    return hdl;
}

pub fn text_create(r: *Renderer) !TextObject.Handle {
    const hdl, const txo = try r.text_objects.add(r.gpa);

    txo.* = .{
        .text = .create(),
        .layout = .create(&r.text.layout_params()),
        .position = .zero,
    };

    return hdl;
}

pub fn text_position(r: *Renderer, hdl: TextObject.Handle, position: vec2) void {
    r.text_objects.get_ptr(hdl).?.position = position;
}

pub fn text_content(r: *Renderer, hdl: TextObject.Handle, content: []const u8) void {
    const Font = struct {
        const fg: hy.Color = .hex(0xfffcfa);
        const fg_u8 = fg.asu8x4();
        const fg_skb: skb.Color = .rgba(fg_u8[0], fg_u8[1], fg_u8[2], fg_u8[3]);

        pub const font: skb.AttributeSet = .from_slice(&.{
            .of_font_size(16.0),
            .of_paint_color(.text, .default, fg_skb),
            .of_baseline_align(.alphabetic),
        });
    };

    const txo = r.text_objects.get_ptr(hdl).?;

    txo.text.reset();
    txo.text.append_utf8(content, .from_slice(&.{}));
    txo.layout.set_from_text(r.text.skb_arena, &r.text.layout_params(), txo.text, Font.font);
}

pub fn font_add(r: *Renderer, family: u8, opts: hy_ui.Text.FontAddOptions) !void {
    try r.text.font_add(family, opts);
}

pub fn camera_position(r: *Renderer, x: u32, y: u32) void {
    r.camera_root_position = .{ x, y, 0 };
}

pub fn sprite_position(r: *Renderer, hdl: Sprite.Handle, position: vec2) void {
    r.sprites.get_ptr(hdl).?.position = position;
}

pub fn sprite_sort_order(r: *Renderer, hdl: Sprite.Handle, sort_order: f32) void {
    r.sprites.get_ptr(hdl).?.sort_order = sort_order;
}

pub fn sprite_time_scale(r: *Renderer, hdl: Sprite.Handle, time_scale: f32) void {
    r.sprites.get_ptr(hdl).?.time_scale = time_scale;
}

pub fn sprite_scale(r: *Renderer, hdl: Sprite.Handle, scale: f32) void {
    r.sprites.get_ptr(hdl).?.scale = scale;
}

pub fn sprite_rotation(r: *Renderer, hdl: Sprite.Handle, rotation: f32) void {
    r.sprites.get_ptr(hdl).?.rotation = rotation;
}

pub fn sprite_flip_x(r: *Renderer, hdl: Sprite.Handle, flip_x: bool) void {
    r.sprites.get_ptr(hdl).?.flip_x = flip_x;
}

pub fn sprite_step(r: *Renderer, hdl: Sprite.Handle, step: ?u32) void {
    r.sprites.get_ptr(hdl).?.step = step;
}

pub fn update(r: *Renderer, delta_time: std.Io.Duration) !void {
    try r.text.atlas_update(r.gpu);

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
    camera.position = .int(r.camera_root_position);

    r.pass.scene = .{
        .view = camera.view(),
        .projection = camera.proj(),
    };

    for (r.sprites.slice()) |*sprite| {
        const ns = @as(f64, @floatFromInt(delta_time.toNanoseconds()));
        const scaled_time: std.Io.Duration = .fromNanoseconds(@trunc(ns * r.time_scale * sprite.time_scale));
        sprite.time = sprite.time.addDuration(scaled_time);

        try r.pass.instance_add(r.atlas, arena, .{
            .position = sprite.position.append(0),
            .sprite = sprite.tag,
            .scale = .splat(sprite.scale),
            .anim_step = sprite.step,
            .anim_time = sprite.time,
            .z_order = sprite.sort_order,
            .rotation = .of(@cos(std.math.degreesToRadians(sprite.rotation)), @sin(std.math.degreesToRadians(sprite.rotation))),
        });
    }

    for (r.text_objects.slice()) |txo| {
        var it = r.text.layout_iterate(txo.layout);
        while (it.next()) |i| {
            try r.pass.custom_add(arena, .{
                // Layout coordinates are y-down, world coordinates are y-up.
                .position = txo.position.addxy(i.position[0], -i.position[1]),
                .texture = i.texture,
                .uv = .{ i.uv_0[0], i.uv_1[0], i.uv_0[1], i.uv_1[1] },
                .size = .arr(i.size),
            });
        }
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
