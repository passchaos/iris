const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const enable_window_renderer_backend = b.option(bool, "enable-window-renderer-backend", "Enable the optional native window rendering backend") orelse false;
    const enable_zgpu_backend = (b.option(bool, "enable-zgpu-backend", "Enable the optional zgpu WebGPU backend integration point") orelse false) or enable_window_renderer_backend;
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_zgpu_backend", enable_zgpu_backend);
    const zgpu_dependency = if (enable_zgpu_backend) b.lazyDependency("zgpu", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const objc_dependency = if (target.result.os.tag == .macos) b.lazyDependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const cangjie_dependency = b.dependency("cangjie", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("iris", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });
    mod.addOptions("iris_build_options", build_options);
    if (zgpu_dependency) |dep| {
        mod.addImport("zgpu", dep.module("root"));
    }
    mod.addImport("cangjie", cangjie_dependency.module("cangjie"));

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "iris",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "iris" is the name you will use in your source code to
                // import this module (e.g. `@import("iris")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, exe);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    const bench_exe = b.addExecutable(.{
        .name = "iris-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, bench_exe);

    const bench_step = b.step("bench", "Run a CPU sparse-strip rendering benchmark");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    const bench_formula_exe = b.addExecutable(.{
        .name = "iris-bench-formula",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/bench_formula.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "cangjie", .module = cangjie_dependency.module("cangjie") },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, bench_formula_exe);
    const bench_formula_step = b.step("bench-formula", "Run a formula draw-list lowering benchmark");
    bench_formula_step.dependOn(&b.addRunArtifact(bench_formula_exe).step);

    const showcase_2d_exe = b.addExecutable(.{
        .name = "iris-showcase-2d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase_2d.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, showcase_2d_exe);
    const showcase_2d_step = b.step("showcase-2d", "Render a 2D showcase image to zig-out/showcase_2d.ppm");
    showcase_2d_step.dependOn(&b.addRunArtifact(showcase_2d_exe).step);

    const showcase_formula_exe = b.addExecutable(.{
        .name = "iris-showcase-formula",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase_formula.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "cangjie", .module = cangjie_dependency.module("cangjie") },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, showcase_formula_exe);
    const showcase_formula_step = b.step("showcase-formula", "Render a formula primitive showcase image to zig-out/showcase_formula.ppm");
    showcase_formula_step.dependOn(&b.addRunArtifact(showcase_formula_exe).step);

    const showcase_3d_exe = b.addExecutable(.{
        .name = "iris-showcase-3d",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase_3d.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, showcase_3d_exe);
    const showcase_3d_step = b.step("showcase-3d", "Render a 3D showcase image to zig-out/showcase_3d.ppm");
    showcase_3d_step.dependOn(&b.addRunArtifact(showcase_3d_exe).step);

    const showcase_3d_sequence_exe = b.addExecutable(.{
        .name = "iris-showcase-3d-sequence",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/showcase_3d_sequence.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, showcase_3d_sequence_exe);
    const showcase_3d_sequence_step = b.step("showcase-3d-sequence", "Render a multi-frame 3D showcase sequence to zig-out/showcase_3d_sequence_*.ppm");
    showcase_3d_sequence_step.dependOn(&b.addRunArtifact(showcase_3d_sequence_exe).step);

    const compare_3d_backends_exe = b.addExecutable(.{
        .name = "iris-compare-3d-backends",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/compare_3d_backends.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, compare_3d_backends_exe);
    const compare_3d_backends_step = b.step("compare-3d-backends", "Compare CPU 3D rendering with the software backend using Image.compare");
    compare_3d_backends_step.dependOn(&b.addRunArtifact(compare_3d_backends_exe).step);

    if (zgpu_dependency != null and objc_dependency != null) {
        const objc_dep = objc_dependency.?;
        const compare_3d_webgpu_exe = b.addExecutable(.{
            .name = "iris-compare-3d-webgpu",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/compare_3d_webgpu.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "iris", .module = mod },
                    .{ .name = "objc", .module = objc_dep.module("objc") },
                    .{ .name = "zgpu", .module = zgpu_dependency.?.module("root") },
                },
            }),
        });
        linkZgpuIfEnabled(zgpu_dependency, compare_3d_webgpu_exe);
        compare_3d_webgpu_exe.root_module.linkSystemLibrary("objc", .{});
        compare_3d_webgpu_exe.root_module.linkFramework("Cocoa", .{});
        compare_3d_webgpu_exe.root_module.linkFramework("CoreFoundation", .{});
        const compare_3d_webgpu_step = b.step("compare-3d-webgpu", "Compare CPU 3D rendering with WebGPU readback on a real device");
        compare_3d_webgpu_step.dependOn(&b.addRunArtifact(compare_3d_webgpu_exe).step);
    }

    const webgpu_window_skeleton_exe = b.addExecutable(.{
        .name = "iris-webgpu-window-skeleton",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/webgpu_window_skeleton.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "iris", .module = mod },
                .{ .name = "iris_build_options", .module = build_options.createModule() },
            },
        }),
    });
    linkZgpuIfEnabled(zgpu_dependency, webgpu_window_skeleton_exe);
    const webgpu_window_skeleton_step = b.step("webgpu-window-skeleton", "Print the external WindowProvider wiring pattern for a WebGPU window app");
    webgpu_window_skeleton_step.dependOn(&b.addRunArtifact(webgpu_window_skeleton_exe).step);

    if (objc_dependency) |objc_dep| {
        const window_cpu_showcase_exe = b.addExecutable(.{
            .name = "iris-window-cpu-showcase",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/window_cpu_showcase.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "iris", .module = mod },
                    .{ .name = "objc", .module = objc_dep.module("objc") },
                },
            }),
        });
        window_cpu_showcase_exe.root_module.linkSystemLibrary("objc", .{});
        window_cpu_showcase_exe.root_module.linkFramework("Cocoa", .{});
        const build_window_cpu_showcase_step = b.step("build-window-cpu-showcase", "Compile the native macOS CPU 2D+3D showcase window");
        build_window_cpu_showcase_step.dependOn(&window_cpu_showcase_exe.step);
        const window_cpu_showcase_step = b.step("window-cpu-showcase", "Open a native macOS window showing Iris 2D and 3D CPU rendering");
        window_cpu_showcase_step.dependOn(&b.addRunArtifact(window_cpu_showcase_exe).step);

        if (zgpu_dependency) |zgpu_dep| {
            const window_webgpu_showcase_exe = b.addExecutable(.{
                .name = "iris-window-webgpu-showcase",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/window_webgpu_showcase.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "iris", .module = mod },
                        .{ .name = "objc", .module = objc_dep.module("objc") },
                        .{ .name = "zgpu", .module = zgpu_dep.module("root") },
                    },
                }),
            });
            linkZgpuIfEnabled(zgpu_dependency, window_webgpu_showcase_exe);
            window_webgpu_showcase_exe.root_module.linkSystemLibrary("objc", .{});
            window_webgpu_showcase_exe.root_module.linkFramework("Cocoa", .{});
            window_webgpu_showcase_exe.root_module.linkFramework("CoreFoundation", .{});
            const build_window_webgpu_showcase_step = b.step("build-window-webgpu-showcase", "Compile the native macOS WebGPU showcase window");
            build_window_webgpu_showcase_step.dependOn(&window_webgpu_showcase_exe.step);
            const window_webgpu_showcase_step = b.step("window-webgpu-showcase", "Open a native macOS WebGPU window using Iris WebGpuBackend");
            window_webgpu_showcase_step.dependOn(&b.addRunArtifact(window_webgpu_showcase_exe).step);
            const smoke_window_webgpu_showcase_cmd = b.addRunArtifact(window_webgpu_showcase_exe);
            smoke_window_webgpu_showcase_cmd.addArgs(&.{ "--frames", "1" });
            const smoke_window_webgpu_showcase_step = b.step("smoke-window-webgpu-showcase", "Run one frame of the native macOS WebGPU window showcase");
            smoke_window_webgpu_showcase_step.dependOn(&smoke_window_webgpu_showcase_cmd.step);
        }
    }

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    linkZgpuIfEnabled(zgpu_dependency, mod_tests);

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    linkZgpuIfEnabled(zgpu_dependency, exe_tests);

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}

pub fn linkWebGpuBackend(iris_dependency: *std.Build.Dependency, compile_step: *std.Build.Step.Compile) void {
    const zgpu_dependency = iris_dependency.builder.lazyDependency("zgpu", .{}) orelse return;
    linkZgpuDependency(zgpu_dependency, compile_step);
}

pub fn linkWindowRenderBackend(iris_dependency: *std.Build.Dependency, compile_step: *std.Build.Step.Compile) void {
    linkWebGpuBackend(iris_dependency, compile_step);
}

fn linkZgpuIfEnabled(zgpu_dependency: ?*std.Build.Dependency, compile_step: *std.Build.Step.Compile) void {
    const dep = zgpu_dependency orelse return;
    linkZgpuDependency(dep, compile_step);
}

fn linkZgpuDependency(dep: *std.Build.Dependency, compile_step: *std.Build.Step.Compile) void {
    const zgpu_build = @import("zgpu");
    compile_step.root_module.linkLibrary(dep.artifact("zdawn"));
    zgpu_build.linkSystemDeps(dep.builder, compile_step);
    addZgpuDawnLibraryPath(dep, compile_step);
    compile_step.root_module.linkSystemLibrary("dawn", .{});
    if (compile_step.rootModuleTarget().os.tag == .macos) {
        compile_step.root_module.linkFramework("CoreFoundation", .{});
    }
}

fn addZgpuDawnLibraryPath(dep: *std.Build.Dependency, compile_step: *std.Build.Step.Compile) void {
    const target = compile_step.rootModuleTarget();
    switch (target.os.tag) {
        .windows => {
            if (dep.builder.lazyDependency("dawn_x86_64_windows_gnu", .{})) |dawn_prebuilt| {
                compile_step.root_module.addLibraryPath(dawn_prebuilt.path(""));
            }
        },
        .linux => {
            if (target.cpu.arch.isX86()) {
                if (dep.builder.lazyDependency("dawn_x86_64_linux_gnu", .{})) |dawn_prebuilt| {
                    compile_step.root_module.addLibraryPath(dawn_prebuilt.path(""));
                }
            } else if (target.cpu.arch.isAARCH64()) {
                if (dep.builder.lazyDependency("dawn_aarch64_linux_gnu", .{})) |dawn_prebuilt| {
                    compile_step.root_module.addLibraryPath(dawn_prebuilt.path(""));
                }
            }
        },
        .macos => {
            if (target.cpu.arch.isX86()) {
                if (dep.builder.lazyDependency("dawn_x86_64_macos", .{})) |dawn_prebuilt| {
                    compile_step.root_module.addLibraryPath(dawn_prebuilt.path(""));
                }
            } else if (target.cpu.arch.isAARCH64()) {
                if (dep.builder.lazyDependency("dawn_aarch64_macos", .{})) |dawn_prebuilt| {
                    compile_step.root_module.addLibraryPath(dawn_prebuilt.path(""));
                }
            }
        },
        else => {},
    }
}
