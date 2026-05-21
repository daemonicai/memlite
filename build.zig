const std = @import("std");

/// Mirrors `Backend` in the llama.cpp.zig fork's build.zig — declared here
/// so we can pass a typed value into `b.dependency(...)` instead of a bare
/// enum literal (Zig 0.16 wants the type).
const LlamaBackend = enum(u8) { cpu, vulkan, metal };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- Vendored C libraries (static, linked into the final exe) ----

    const sqlite_lib = buildSqlite(b, target, optimize);
    const sqlite_vec_lib = buildSqliteVec(b, target, optimize);
    const md4c_lib = buildMd4c(b, target, optimize);

    // ---- llama.cpp bindings (daemonicai fork pinned in build.zig.zon) ----
    // CPU-only in v1 by design — keeps the binary self-contained (no
    // default.metallib sidecar) and dodges the Metal Toolchain dependency.
    const llama_dep = b.dependency("llama_cpp_zig", .{
        .target = target,
        .optimize = optimize,
        .backend = @as(LlamaBackend, .cpu),
    });
    const llama_lib = llama_dep.artifact("llama_cpp");

    // ---- memlite executable ----

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addIncludePath(b.path("third_party/sqlite"));
    exe_mod.addIncludePath(b.path("third_party/sqlite-vec"));
    exe_mod.addIncludePath(b.path("third_party/md4c"));
    exe_mod.linkLibrary(sqlite_lib);
    exe_mod.linkLibrary(sqlite_vec_lib);
    exe_mod.linkLibrary(md4c_lib);
    exe_mod.linkLibrary(llama_lib);
    exe_mod.addImport("llama_c", llama_dep.module("c"));

    const exe = b.addExecutable(.{
        .name = "memlite",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run memlite");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}

fn buildSqlite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("third_party/sqlite"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_FTS5",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
            "-DSQLITE_MAX_EXPR_DEPTH=0",
            "-DSQLITE_OMIT_DECLTYPE",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_USE_ALLOCA",
            "-w",
        },
    });
    return b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = mod,
    });
}

fn buildSqliteVec(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("third_party/sqlite"));
    mod.addIncludePath(b.path("third_party/sqlite-vec"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite-vec/sqlite-vec.c"),
        .flags = &.{
            "-DSQLITE_CORE",
            "-w",
        },
    });
    return b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite-vec",
        .root_module = mod,
    });
}

fn buildMd4c(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("third_party/md4c"));
    mod.addCSourceFile(.{
        .file = b.path("third_party/md4c/md4c.c"),
        .flags = &.{"-w"},
    });
    return b.addLibrary(.{
        .linkage = .static,
        .name = "md4c",
        .root_module = mod,
    });
}
