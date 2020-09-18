const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const main_tests = b.addTest("tests/adma_tests.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackagePath("adma", "src/adma.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const dlib = b.addSharedLibrary("adma", "src/externs.zig", b.version(1, 0, 0));
    dlib.setBuildMode(mode);
    dlib.addPackagePath("adma", "src/adma.zig");
    dlib.single_threaded = true;
    dlib.install();

    const shared_step = b.step("shared", "Create Shared library");
    shared_step.dependOn(&dlib.step);
}
