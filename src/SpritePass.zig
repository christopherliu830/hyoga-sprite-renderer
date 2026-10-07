const SpritePass = @This();

const std = @import("std");
const hy = @import("hyoga");
const Renderer = @import("Renderer.zig");

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
    color: hy.Color,
    z_order: f32 = 0,

    const Repr = extern struct {
        position_world: [2]f32,
        _padding_0: [2]f32 = .{ 0, 0 },
        rotation: [2]f32,
        scale: [2]f32,
        uv: [4]f32,
        color: [4]f32,

        comptime {
            assert(@sizeOf(Repr) == 4 * 16);
        }
    };

    fn repr(instance: Instance) Repr {
        return .{
            .position_world = instance.position_world.array,
            .rotation = instance.rotation.array,
            .scale = instance.scale.array,
            .uv = instance.uv,
            .color = instance.color.asvec4_norm(),
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

pub fn init(gpa: std.mem.Allocator, gpu: Gpu) !SpritePass {
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

pub fn deinit(sp: *SpritePass, gpu: Gpu) void {
    sp.pipeline.deinit(gpu);
    sp.sampler.deinit(gpu);
    sp.dya.deinit();
}

pub fn prepare(sp: *SpritePass, gpu: Gpu, cmd: Gpu.CommandBuffer) !void {
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

pub fn render(sp: *SpritePass, r: *Renderer, cmd: Gpu.CommandBuffer, pass: Gpu.RenderPass) void {
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

        pass.bind_samplers(gpu, .{
            .stage = .fragment,
            .slot = 0,
            .bindings = &.{
                .{ .texture = r.atlas.texture, .sampler = sp.sampler },
            },
        });

        pass.bind_pipeline(gpu, sp.pipeline);

        cmd.uniform_push(gpu, .vertex, 0, ctx.instances.offset) catch {
            std.log.warn("cmd uniform push failed", .{});
        };

        pass.draw(gpu, .{ .vertex_count = @intCast(6 * sp.instances.items.len) });

        sp.pending_render_ctx = null;
        sp.instances = .empty;
    }
}

pub fn instance_add(sp: *SpritePass, r: *Renderer, arena: std.mem.Allocator, opts: struct {
    position: vec3,
    sprite: u32,
    rotation: vec2 = .px,
    scale: vec2 = .one,
    anim_time: std.Io.Timestamp = .zero,
    anim_speed: f32 = 1.0,
    anim_step: ?u32 = null,
    anim_step_offset: u32 = 0,
    anim_flip: bool = false,
    color: hy.Color = .white,
    z_order: f32 = 0.0,
}) !void {
    const rate = opts.anim_speed;
    const unclamped_step = @as(u32, @trunc(hy.time.ttos(opts.anim_time) * rate)) + opts.anim_step_offset;
    const region_count = r.atlas.count_tag(opts.sprite);
    const step = if (opts.anim_step) |s| s else unclamped_step % region_count;
    const image = r.atlas.get_tag(opts.sprite, step);
    const position = opts.position;

    var scale = opts.scale.mulxy(@floatFromInt(image.w), @floatFromInt(image.h));

    var offset: vec2 = blk: {
        if (image.origin_x == 0 and image.origin_y == 0) break :blk .zero;

        // Image coordinates are (0,0) at the top left.
        // The image's top left is at `image.trim_offset_{xy}`.
        // The image's pivot is at `image.origin_{xy}`.
        // So, in order to render the image at the pivot location,
        // We need to translate the image left by the difference
        // of the origin and the trim offset.
        const pivot_x = image.origin_x - @as(i64, image.trim_offset_x);
        const pivot_y = image.origin_y - @as(i64, image.trim_offset_y);

        break :blk .of(
            -@as(f32, @floatFromInt(pivot_x)),
            @as(f32, @floatFromInt(pivot_y)),
        );
    };

    if (opts.anim_flip) {
        offset = offset.mulxy(-1, 1);
        scale = scale.mulxy(-1, 1);
    }

    const uv = r.atlas.uv(image);

    _ = try sp.instances.append(arena, .{
        .position_world = position.xy().add(offset),
        .rotation = opts.rotation,
        .scale = scale,
        .uv = uv,
        .color = opts.color,
        .z_order = opts.z_order,
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
