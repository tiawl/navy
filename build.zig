const std = @import("std");

const TestSteps = struct {
    unit_test_step: *std.Build.Step,
    integration_test_step: *std.Build.Step,
};

fn buildOptions(builder: *std.Build) !*std.Build.Module {
    const options = builder.addOptions();

    var code: u8 = undefined;
    const git = try builder.findProgram(&.{
        "git",
    }, &.{});
    const raw_git_describe = try builder.runAllowFail(&[_][]const u8{
        git,     "-C",     builder.build_root.path orelse ".", "describe", "--match",
        "*.*.*", "--tags", "--abbrev=9",
    }, &code, .Ignore);
    const git_describe = std.mem.trim(u8, raw_git_describe, " \n\r");

    var it = std.mem.splitScalar(u8, git_describe, '.');
    const navy_version = it.next().?;
    const navy_feature = it.next().?;
    _ = try std.fmt.parseInt(u32, navy_version, 10);
    _ = try std.fmt.parseInt(u32, navy_feature, 10);

    const navy_patch = switch (std.mem.count(u8, git_describe, "-")) {
        // Tagged commit
        0 => it.next().?,
        // Untagged commit
        2 => blk: {
            it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const sem_version = try std.SemanticVersion.parse(builder.fmt("{s}.{s}.0", .{
                navy_version, navy_feature,
            }));
            const ancestor_version = try std.SemanticVersion.parse(tagged_ancestor);
            if (sem_version.order(ancestor_version) != .eq) {
                std.debug.print("Semantic version '{}.{}.{}' must be equal to tagged ancestor '{}.{}.{}'\n", .{
                    sem_version.major, sem_version.minor, sem_version.patch, ancestor_version.major, ancestor_version.minor, ancestor_version.patch,
                });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("Unexpected `git describe` output: {s}\n", .{
                    git_describe,
                });
                std.process.exit(1);
            }

            _ = try std.fmt.parseInt(u32, commit_height, 10);
            break :blk builder.fmt("{s}+{s}", .{
                commit_height, commit_id[1..],
            });
        },
        else => {
            std.debug.print("Unexpected `git describe` output: {s}\n", .{
                git_describe,
            });
            std.process.exit(1);
        },
    };
    const version = builder.fmt("{s}.{s}.{s}", .{
        navy_version, navy_feature, navy_patch,
    });
    options.addOption([:0]const u8, "version", try builder.allocator.dupeZ(u8, version));
    return options.createModule();
}

pub fn build(builder: *std.Build) !void {
    const target = builder.standardTargetOptions(.{});
    const optimize = builder.standardOptimizeOption(.{});

    var back = builder.addModule("navy", .{
        .root_source_file = .{
            .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                "src", "backend", "index.zig",
            }),
        },
        .target = target,
        .optimize = optimize,
    });

    const front = builder.addExecutable(.{
        .name = "navy",
        .root_module = builder.createModule(.{
            .root_source_file = .{
                .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                    "src", "frontend", "main.zig",
                }),
            },
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "build_options",
                    .module = try buildOptions(builder),
                },
                .{
                    .name = "backend",
                    .module = back,
                },
            },
        }),
    });

    builder.installArtifact(front);

    const test_steps: TestSteps = steps: {
        const recover = builder.dependency("zig-recover", .{
            .target = target,
            .optimize = .Debug,
        }).module("recover");

        const unit_test_step = step: {
            const back_unit_tests = builder.addTest(.{
                .test_runner = .{
                    .path = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "runner.zig",
                        }),
                    },
                    .mode = .simple,
                },
                .root_module = builder.createModule(.{
                    .root_source_file = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "backend", "unit.zig",
                        }),
                    },
                    .target = target,
                    .optimize = .Debug,
                }),
            });
            for (back.import_table.keys(), back.import_table.values()) |name, module|
                back_unit_tests.root_module.addImport(name, module);
            back_unit_tests.root_module.addImport("recover", recover);

            back_unit_tests.step.dependOn(builder.getInstallStep());

            const back_unit_tests_runner = builder.addRunArtifact(back_unit_tests);

            const front_unit_tests = builder.addTest(.{
                .test_runner = .{
                    .path = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "runner.zig",
                        }),
                    },
                    .mode = .simple,
                },
                .root_module = builder.createModule(.{
                    .root_source_file = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "frontend", "unit.zig",
                        }),
                    },
                    .target = target,
                    .optimize = .Debug,
                }),
            });
            for (front.root_module.import_table.keys(), front.root_module.import_table.values()) |name, module|
                front_unit_tests.root_module.addImport(name, module);
            front_unit_tests.root_module.addImport("recover", recover);

            front_unit_tests.step.dependOn(builder.getInstallStep());

            const front_unit_tests_runner = builder.addRunArtifact(front_unit_tests);

            const unit_test_step = builder.step("test-unit", "Run unit tests");
            unit_test_step.dependOn(&back_unit_tests_runner.step);
            unit_test_step.dependOn(&front_unit_tests_runner.step);

            break :step unit_test_step;
        };

        const integration_test_step = step: {
            const index = builder.createModule(.{
                .root_source_file = .{
                    .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                        "src", "frontend", "index.zig",
                    }),
                },
                .target = target,
                .optimize = .Debug,
            });

            for (front.root_module.import_table.keys(), front.root_module.import_table.values()) |name, module|
                index.addImport(name, module);

            const integration_tests = builder.addTest(.{
                .test_runner = .{
                    .path = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "runner.zig",
                        }),
                    },
                    .mode = .simple,
                },
                .root_module = builder.createModule(.{
                    .root_source_file = .{
                        .cwd_relative = try builder.build_root.join(builder.allocator, &.{
                            "src", "frontend", "integration.zig",
                        }),
                    },
                    .target = target,
                    .optimize = .Debug,
                }),
            });

            for (front.root_module.import_table.keys(), front.root_module.import_table.values()) |name, module|
                integration_tests.root_module.addImport(name, module);
            integration_tests.root_module.addImport("index", index);
            integration_tests.root_module.addImport("recover", recover);

            const integration_test_runner = builder.addRunArtifact(integration_tests);

            const integration_test_step = builder.step("test-integration", "Run integration tests");
            integration_test_step.dependOn(&integration_test_runner.step);

            const coverage_step = builder.step("coverage", "Generate coverage");

            const kcov = try builder.findProgram(&.{
                "kcov",
            }, &.{});
            const include_pattern = builder.fmt("--include-pattern={s}/src/", .{
                builder.build_root.path.?,
            });
            const exclude_pattern = builder.fmt("--exclude-pattern={s}/,{s}/", .{
                builder.cache_root.path.?,
                builder.graph.global_cache_root.path.?,
            });
            const coverage_runner = builder.addSystemCommand(&.{
                kcov, "--clean", include_pattern, exclude_pattern, "coverage/",
            });

            coverage_runner.addArtifactArg(integration_tests);

            coverage_step.dependOn(&coverage_runner.step);

            break :step integration_test_step;
        };

        break :steps .{
            .unit_test_step = unit_test_step,
            .integration_test_step = integration_test_step,
        };
    };

    const test_step = builder.step("test", "Run all tests");
    test_step.dependOn(test_steps.unit_test_step);
    test_step.dependOn(test_steps.integration_test_step);
}
