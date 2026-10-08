const std = @import("std");
const hyoga = @import("hyoga");
const hyoga_rt = @import("hyoga_rt");
const asset_pack = @import("asset_pack");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const hy_ui = b.dependency("hyoga_ui", .{});
    const hy = b.dependency("hyoga", .{});

    const hpf = asset_pack.pack(b, b.dependency("asset_pack", .{}), @import("manifest.zon"));

    const hy_sprite = b.addModule("hy_sprite", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "hyoga", .module = hy.module("core") },
            .{ .name = "hy_ui", .module = hy_ui.module("ui") },
        },
    });

    hyoga.embed_shaders(b, hy_sprite, .{
        .target = target,
        .files = embed_shaders,
    });

    const runner: hyoga_rt.Runner = .{
        .target = target,
        .optimize = optimize,
        .rt_dep = b.dependency("hyoga_rt", .{}),
        .hyoga_module = hy.module("core"),
    };

    const exe = b.addExecutable(.{
        .name = "basic",
        .root_module = runner.entrypoint(b, b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("tests/basic.zig"),
            .imports = &.{
                .{ .name = "hyoga", .module = hy.module("core") },
                .{ .name = "hy_sprite", .module = hy_sprite },
                .{ .name = "blob", .module = b.createModule(.{ .root_source_file = hpf.blob }) },
            },
        })),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run sample");
    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);
}

const embed_shaders: []const []const u8 = &.{
    "shaders/billboard.slang",
    "shaders/billboard.zon",
};
