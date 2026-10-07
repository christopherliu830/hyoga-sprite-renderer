const std = @import("std");
const hy = @import("hyoga");
const hyspr = @import("hyspr");
const Renderer = hyspr.Renderer;

const blob_embed align(hy.PackFile.blob_align) = @embedFile("blob").*;

const Application = struct {
    surface: hy.Rt.Surface,
    renderer: Renderer,

    pub fn cast(ptr: *anyopaque) *Application {
        return @ptrCast(@alignCast(ptr));
    }
};

pub fn entry(rt: hy.Rt, _: std.process.Init.Minimal) !hy.Rt.Application {
    const app = try rt.gpa.create(Application);
    errdefer rt.gpa.destroy(app);

    const surface: hy.Rt.Surface = try .init(rt, .{
        .title = "Sprite Renderer Basic",
        .size = .{ 1280, 720 },
    });

    errdefer surface.deinit(rt);

    var renderer = try renderer_init(rt, surface);
    errdefer renderer.deinit(rt);

    _ = try renderer.add("special");

    app.* = .{
        .surface = surface,
        .renderer = renderer,
    };

    return .{
        .ptr = app,
        .vtable = &.{
            .update = update,
            .deinit = deinit,
        },
    };
}

pub fn deinit(ctx: *anyopaque, rt: hy.Rt) void {
    const app: *Application = .cast(ctx);
    app.renderer.deinit(rt);
    app.surface.deinit(rt);
    rt.gpa.destroy(app);
}

pub fn update(ctx: *anyopaque, rt: hy.Rt, delta_time: std.Io.Duration) !void {
    _ = rt;
    const app: *Application = .cast(ctx);

    var buffer: [32]hy.Rt.Surface.Event = undefined;
    var it = app.surface.events_iterator(&buffer);

    while (try it.next()) |ev| {
        _ = ev;
    }

    app.renderer.update(delta_time) catch return error.RuntimeError;
}

fn renderer_init(rt: hy.Rt, surface: hy.Rt.Surface) !Renderer {
    var blob: hy.PackFile.Blob = .init_buffer(blob_embed[0..]);
    errdefer blob.deinit(rt.io);

    var renderer: Renderer = try .init(rt, surface, .{
        .blob = blob,
        .viewport_size = .{ 128, 128 },
    });

    renderer.time_scale = 12.0;

    return renderer;
}
