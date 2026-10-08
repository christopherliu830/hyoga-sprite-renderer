const RenderPass = @This();

const std = @import("std");
const hy = @import("hyoga");
const Renderer = @import("Sprites.zig");
const Atlas = @import("Atlas.zig");

const hym = hy.math;
const vec2 = hy.math.vec2;
const vec3 = hy.math.vec3;
const vec4 = hy.math.vec4;
const mat4 = hy.math.mat4;
const Gpu = hy.Rt.Gpu;
const Pipeline = Gpu.Pipeline;
const Sampler = Gpu.Sampler;
const Texture = Gpu.Texture;
const Buffer = Gpu.Buffer;
const assert = std.debug.assert;

const sprites_max = 8 * 1024;

dya: hy.Rt.Gpu.DynamicArena,
scene: Scene,
instances: std.ArrayList(Instance),
pipeline: Pipeline,
sampler: Sampler,
pending_render_ctx: ?RenderContext,
units_per_pixel: f32 = 1.0,

pub const Program = enum(u8) {
    lit,
    unlit,
    depth_only,
};

pub const Scene = struct {
    view: mat4,
    projection: mat4,

    pub const Repr = extern struct {
        view: [4][4]f32,
        projection: [4][4]f32,
        view_projection: [4][4]f32,
    };

    pub fn repr(scene: Scene) Repr {
        return .{
            .view = scene.view.m,
            .projection = scene.projection.m,
            .view_projection = scene.view.mul(scene.projection).m,
        };
    }
};

pub const Instance = struct {
    position_world: vec2,

    /// A normalized direction vector.
    /// If you have an angle, apply @cos(), @sin()
    /// and pass to this object.
    rotation: vec2,
    scale: vec2,
    uv: [4]f32,
    tint_color: hy.Color,
    emit_color: hy.Color,
    z_order: f32 = 0,
    texture: Gpu.Texture,

    const Repr = extern struct {
        position_world: [2]f32,
        _padding_0: [2]f32 = .{ 0, 0 },
        rotation: [2]f32,
        scale: [2]f32,
        uv: [4]f32,
        tint_color: [4]f32,
        emit_color: [4]f32,

        comptime {
            assert(@sizeOf(Repr) == 4 * 20);
        }
    };

    fn repr(instance: Instance) Repr {
        return .{
            .position_world = instance.position_world.array,
            .rotation = instance.rotation.array,
            .scale = instance.scale.array,
            .uv = instance.uv,
            .tint_color = instance.tint_color.asvec4_norm(),
            .emit_color = instance.emit_color.asvec4_norm(),
        };
    }

    fn lessThan(_: void, a: Instance, b: Instance) bool {
        return a.z_order < b.z_order;
    }
};

const RenderContext = struct {
    scene: Gpu.Buffer,
    instances: Gpu.Buffer,
};

pub fn init(gpa: std.mem.Allocator, gpu: Gpu) !RenderPass {
    const pipeline = try pipeline_init(gpu);
    const dya: Gpu.DynamicArena = .init(gpa, gpu, .{ .graphics_storage = true });

    return .{
        .dya = dya,
        .pipeline = pipeline,
        .sampler = try .init(gpu, .{
            .min_filter = .nearest,
            .mag_filter = .nearest,
        }),
        .instances = .empty,
        .scene = .{ .view = .identity, .projection = .identity },
        .pending_render_ctx = null,
    };
}

pub fn deinit(sp: *RenderPass, gpu: Gpu) void {
    sp.pipeline.deinit(gpu);
    sp.sampler.deinit(gpu);
    sp.dya.deinit();
}

pub fn prepare(sp: *RenderPass, gpu: Gpu, cmd: Gpu.CommandBuffer) !void {
    sp.instances.shrinkRetainingCapacity(@min(sprites_max, sp.instances.items.len));

    std.sort.pdq(Instance, sp.instances.items, {}, Instance.lessThan);
    const n: u32 = @intCast(sp.instances.items.len);

    const scene = try sp.dya.create(Scene.Repr);
    scene.cpu.* = sp.scene.repr();

    const sprites = try sp.dya.alloc(Instance.Repr, n);

    for (sprites.cpu, sp.instances.items) |*dst, src| {
        dst.* = src.repr();
    }

    sp.pending_render_ctx = .{
        .scene = scene.gpu,
        .instances = sprites.gpu,
    };

    try sp.dya.finish(gpu, cmd);
}

pub fn render(sp: *RenderPass, r: *Renderer, cmd: Gpu.CommandBuffer, pass: Gpu.RenderPass) void {
    const gpu = r.gpu;

    if (sp.instances.items.len == 0) return;

    if (sp.pending_render_ctx) |ctx| {
        pass.bind_storage_buffers(gpu, .{
            .stage = .vertex,
            .slot = 0,
            .buffers = &.{
                ctx.scene.hdl,
                ctx.instances.hdl,
            },
        });

        var current_texture: Gpu.Texture = sp.instances.items[0].texture;
        var base: usize = 0;
        var i: usize = 0;

        pass.bind_pipeline(gpu, sp.pipeline);

        while (i < sp.instances.items.len) : (i += 1) {
            const instance = sp.instances.items[i];

            if (instance.texture != current_texture) {
                if (current_texture != .none) {
                    pass.bind_samplers(gpu, .{
                        .stage = .fragment,
                        .slot = 0,
                        .bindings = &.{
                            .{ .texture = current_texture, .sampler = sp.sampler },
                        },
                    });

                    cmd.uniform_push(gpu, .vertex, 0, ctx.instances.offset + @sizeOf(Instance.Repr) * base) catch unreachable;

                    pass.draw(gpu, .{ .vertex_count = @intCast(6 * (i - base)) });
                }

                base = i;
                current_texture = instance.texture;
            }
        }

        if (i > base) {
            if (current_texture != .none) {
                pass.bind_samplers(gpu, .{
                    .stage = .fragment,
                    .slot = 0,
                    .bindings = &.{
                        .{ .texture = current_texture, .sampler = sp.sampler },
                    },
                });

                cmd.uniform_push(gpu, .vertex, 0, ctx.instances.offset + @sizeOf(Instance.Repr) * base) catch unreachable;
                pass.draw(gpu, .{ .vertex_count = @intCast(6 * (i - base)) });
            }
        }

        sp.pending_render_ctx = null;
        sp.instances = .empty;
    }
}

pub fn instance_add(sp: *RenderPass, atlas: Atlas, arena: std.mem.Allocator, opts: struct {
    position: vec3,
    sprite: Atlas.Tag,
    rotation: vec2 = .px,
    scale: vec2 = .one,
    anim_time: std.Io.Timestamp = .zero,
    anim_speed: f32 = 1.0,
    anim_step: ?u32 = null,
    anim_step_offset: u32 = 0,
    anim_flip_x: bool = false,
    anim_flip_y: bool = false,
    anim_loop: bool = true,
    tint_color: hy.Color = .white,
    emit_color: hy.Color = .none,
    z_order: f32 = 0.0,
}) !void {
    const rate = opts.anim_speed;
    const unclamped_step = @as(u32, @trunc(hy.time.ttos(opts.anim_time) * rate)) + opts.anim_step_offset;
    const region_count = atlas.count_tag(opts.sprite);

    const step = if (opts.anim_step) |s|
        s
    else if (opts.anim_loop)
        unclamped_step % region_count
    else
        @min(unclamped_step, region_count - 1);

    const image = atlas.get_tag(opts.sprite, step);
    const position = opts.position;

    const scale = opts.scale.mulxy(@floatFromInt(image.w), @floatFromInt(image.h));

    const offset: vec2 = blk: {
        const ox: f32 = @floatFromInt(image.origin_x);
        const oy: f32 = @floatFromInt(image.origin_y);
        const tx: f32 = @floatFromInt(image.trim_offset_x);
        const ty: f32 = @floatFromInt(image.trim_offset_y);
        const sx: f32 = @floatFromInt(image.source_width);
        const sy: f32 = @floatFromInt(image.source_height);

        // The sprite should behave as its untrimmed source image would:
        // a `source_{width,height}` quad whose pivot (`image.origin_{xy}`)
        // sits on `position`, rotated about the source image's center.
        // The quad we actually draw is the trimmed rect, whose top left is
        // at `image.trim_offset_{xy}` in the source image, and the shader
        // rotates it about its own center, which moves with the trim.
        const pivot = vec2.of(ox, -oy).mul(opts.scale);
        const trim = vec2.of(tx, -ty).mul(opts.scale);
        const source_center = vec2.of(sx, -sy).mul(opts.scale).muls(0.5);
        const sprite_center: vec2 = scale.mulxy(0.5, -0.5);

        // Arm from the source center to the trimmed center. Rotating it
        // here makes the shader's rotation about `center` equivalent to
        // one about `source_center`.
        const arm = trim.add(sprite_center).sub(source_center);
        const arm_rot = arm.rotate_dir(opts.rotation);
        break :blk arm_rot.add(source_center).sub(pivot).sub(sprite_center);
    };

    var uv = atlas.uv(image);

    if (opts.anim_flip_x) {
        std.mem.swap(f32, &uv[0], &uv[1]);
    }

    if (opts.anim_flip_y) {
        std.mem.swap(f32, &uv[2], &uv[3]);
    }

    _ = try sp.instances.append(arena, .{
        .position_world = position.xy().add(offset),
        .rotation = opts.rotation,
        .scale = scale,
        .uv = uv,
        .z_order = opts.z_order,
        .texture = atlas.texture,
        .emit_color = opts.emit_color,
        .tint_color = opts.tint_color,
    });
}

pub fn custom_add(sp: *RenderPass, arena: std.mem.Allocator, opts: struct {
    position: vec2,
    rotation: vec2 = .px,
    size: vec2,
    texture: Gpu.Texture,
    uv: [4]f32,
    tint_color: hy.Color = .white,
    emit_color: hy.Color = .none,
    z_order: f32 = 0.0,
}) !void {
    _ = try sp.instances.append(arena, .{
        .position_world = opts.position,
        .rotation = opts.rotation,
        .scale = opts.size,
        .uv = opts.uv,
        .tint_color = opts.tint_color,
        .emit_color = opts.emit_color,
        .z_order = opts.z_order,
        .texture = opts.texture,
    });
}

fn pipeline_init(gpu: Gpu) !Pipeline {
    const Shaders = struct {
        const billboard_slang align(4) = @embedFile("shaders/billboard.slang").*;
        const billboard_zon align(4) = @embedFile("shaders/billboard.zon").*;
    };

    const vertex: Gpu.Shader = try .init(gpu, .{
        .stage = .vertex,
        .entrypoint = "vertex_main",
        .code = Shaders.billboard_slang[0..],
        .metadata = Shaders.billboard_zon[0..],
    });

    defer vertex.deinit(gpu);

    const fragment: Gpu.Shader = try .init(gpu, .{
        .stage = .fragment,
        .entrypoint = "fragment_main",
        .code = Shaders.billboard_slang[0..],
        .metadata = Shaders.billboard_zon[0..],
    });

    defer fragment.deinit(gpu);

    const pipeline: Gpu.Pipeline = try .init(gpu, .{
        .vertex_shader = vertex,
        .fragment_shader = fragment,
        .color_targets = &.{.{ .format = .swapchain(gpu) }},
    });

    return pipeline;
}
