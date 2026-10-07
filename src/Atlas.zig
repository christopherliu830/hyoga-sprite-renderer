const Atlas = @This();

const std = @import("std");
const hy = @import("hyoga");
const stbi = @import("stb_image");

const Gpu = hy.Rt.Gpu;

texture: Gpu.Texture,
metadata: hy.PackFile.ImageAtlas,
tags: std.StringHashMapUnmanaged(u32),

pub fn init(gpa: std.mem.Allocator, gpu: Gpu, blob: hy.PackFile.Blob) !Atlas {
    const atlas: Gpu.Texture = atlas: {
        const atlas_blob = try blob.load("atlas_image");
        const img, const w, const h = try stbi_load(atlas_blob);

        defer stbi_free(img);

        break :atlas try .from_memory(gpu, .{
            .name = "Atlas",
            .width = w,
            .height = h,
            .bytes = img,
        });
    };

    const metadata: hy.PackFile.ImageAtlas = meta: {
        const meta_blob = try blob.load("atlas_metadata");
        break :meta try .from_bytes(meta_blob);
    };

    var tags: std.StringHashMapUnmanaged(u32) = .empty;

    defer tags.deinit(gpa);

    for (metadata.tags, 0..) |*tag, i| {
        const name = tag.name();
        try tags.put(gpa, name, @intCast(i));
    }

    return .{
        .texture = atlas,
        .metadata = metadata,
        .tags = tags.move(),
    };
}

pub fn deinit(a: *Atlas, gpa: std.mem.Allocator, gpu: Gpu) void {
    a.texture.deinit(gpu);
    a.tags.deinit(gpa);
}

pub fn uv(a: Atlas, image: hy.PackFile.ImageAtlas.Image) [4]f32 {
    const x: f32 = @floatFromInt(image.x);
    const y: f32 = @floatFromInt(image.y);
    const w: f32 = @floatFromInt(image.w);
    const h: f32 = @floatFromInt(image.h);
    const mw: f32 = @floatFromInt(a.metadata.width);
    const mh: f32 = @floatFromInt(a.metadata.height);

    return .{
        x / mw,
        (x + w) / mw,
        y / mh,
        (y + h) / mh,
    };
}

pub fn get(a: Atlas, name: []const u8, step: u32) hy.PackFile.ImageAtlas.Image {
    const tag = a.tags.get(name).?;
    return a.get_tag(tag, step);
}

pub fn get_tag(a: Atlas, tag: u32, step: u32) hy.PackFile.ImageAtlas.Image {
    const region = a.metadata.tags[tag];
    const image_index = a.metadata.tag_images[region.start..region.end][step];
    return a.metadata.images[image_index];
}

pub fn count(a: Atlas, name: []const u8) u32 {
    const tag = a.tags.get(name).?;
    return count_tag(tag);
}

pub fn count_tag(a: Atlas, tag: u32) u32 {
    const region = a.metadata.tags[tag];
    return region.end - region.start;
}

fn stbi_load(bytes: []const u8) !struct { []u8, u32, u32 } {
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;

    const image = stbi.stbi_load_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &w,
        &h,
        &channels,
        4,
    );

    const len: u32 = @intCast(w * h * 4);

    if (w == 0 and image == null) return error.InvalidTextureData;

    return .{ image[0..len], @intCast(w), @intCast(h) };
}

fn stbi_free(image: []u8) void {
    defer stbi.stbi_image_free(image.ptr);
}
