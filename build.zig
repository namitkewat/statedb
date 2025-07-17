const std = @import("std");

pub fn build(b: *std.Build) void {
    // --- Step 1: Configure Target and Optimization ---
    // Standard options for cross-compilation and optimization.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Step 2: Define Dependencies via Git Submodule ---
    // Instead of using the package manager, we are loading 'zig-clap' as a
    // Git submodule. This gives us precise control over the exact version used,
    // which is useful for older tags that may not be compatible with the
    // latest `build.zig.zon` format.
    //
    // The submodule was added using these commands:
    //   git submodule add https://github.com/Hejsil/zig-clap libs/zig-clap
    //   cd libs/zig-clap
    //   git checkout tags/v0.10.0
    //
    // We then use `b.createModule` to import the dependency's root source file.
    const clap_module = b.createModule(.{
        .root_source_file = b.path("libs/zig-clap/clap.zig"),
    });

    // --- Step 3.1: Create the Executable Artifact ---
    const exe = b.addExecutable(.{
        .name = "statedb",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the 'clap' module to our executable.
    exe.root_module.addImport("clap", clap_module);

    // --- Step 3.2: Add build step for the shared library ---
    const lib = b.addSharedLibrary(.{
        .name = "statedb", // Output: libstatedb_ffi.so, statedb_ffi.dll, etc.
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    // This makes the library available to be built with `zig build lib`
    const lib_step = b.step("lib", "Build the shared library");
    lib_step.dependOn(b.getInstallStep());
    b.installArtifact(lib);

    // --- Step 3.2: Add build step for the shared library ---
    const lib_parser = b.addSharedLibrary(.{
        .name = "statedb_parser", // Output: libstatedb_ffi.so, statedb_ffi.dll, etc.
        .root_source_file = b.path("src/parser_ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Link libc for C interoperability
    lib_parser.linkLibC();
    lib_parser.linkLibrary(lib);
    // This makes the library available to be built with `zig build lib`
    // const lib_parser_step = b.step("statedb_parser", "Build the shared library for FFI demo");
    // lib_parser_step.dependOn(b.getInstallStep());
    b.installArtifact(lib_parser);

    // --- Step 4: Create the Test Artifact ---
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Also link the 'clap' module to our tests so they can be compiled.
    unit_tests.root_module.addImport("clap", clap_module);

    // --- Step 5: Define the Build Steps ---

    // The "install" step copies the executable to zig-out/bin.
    // This is the default step when running `zig build`.
    b.installArtifact(exe);

    // The "run" step executes the compiled application.
    // It depends on the install step to ensure the executable is in a known location.
    // Usage: `zig build run -- [args]`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // The "test" step runs the unit tests.
    // Usage: `zig build test`
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
