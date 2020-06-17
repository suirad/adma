const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("adma", "src/adma.zig");
    lib.setBuildMode(mode);
    //lib.install();

    var main_tests = b.addTest("tests/adma_tests.zig");
    main_tests.setBuildMode(mode);
    main_tests.addPackagePath("adma", "src/adma.zig");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
