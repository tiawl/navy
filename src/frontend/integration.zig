const std = @import("std");

const recover = @import("recover");

const index = @import("index");
const navy = index.navy;

const ArgIterator = index.options.ArgIterator;

fn oops() noreturn {
    @panic("Oops");
}

test "success: navy --standard-options --for-success" {
    const allocator = std.testing.allocator;
    var args = ArgIterator.init(allocator, &[_][:0]const u8{
        "navy", // "--standard-options", "--for-success",
    });
    defer args.deinit();
    try navy.init(allocator, &args);
    defer navy.deinit();

    try navy.instance().run();
}

test "success: navy -V" {
    const allocator = std.testing.allocator;
    var args = ArgIterator.init(allocator, &[_][:0]const u8{
        "navy", "-V",
    });
    defer args.deinit();
    try navy.init(allocator, &args);
    defer navy.deinit();

    try navy.instance().run();
}

test "panic_before_init: navy --panic-option --before-init" {
    const allocator = std.testing.allocator;
    var args = ArgIterator.init(allocator, &[_][:0]const u8{
        "navy", //"--panic-option", "--before-init",
    });
    defer args.deinit();
    try std.testing.expectError(error.Panic, recover.call(oops, .{}));
}

test "panic_after_init: navy --panic-option --after-init" {
    const allocator = std.testing.allocator;
    var args = ArgIterator.init(allocator, &[_][:0]const u8{
        "navy", //"--panic-option", "--after-init",
    });
    defer args.deinit();
    try navy.init(allocator, &args);
    defer navy.deinit();
    try std.testing.expectError(error.Panic, recover.call(oops, .{}));
}

// TODO: add more integration tests
