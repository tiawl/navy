const std = @import("std");

// TODO: remove this for the next Zig release
pub fn Fifo(comptime T: type) type {
    return struct {
        buffer: []T,
        head: usize,
        len: usize,

        pub const empty: @This() = .{
            .buffer = &.{},
            .head = 0,
            .len = 0,
        };

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            gpa.free(self.buffer);
            self.* = undefined;
        }

        pub fn ensureTotalCapacity(self: *@This(), gpa: std.mem.Allocator, new_capacity: usize) std.mem.Allocator.Error!void {
            if (self.buffer.len >= new_capacity) return;
            return self.ensureTotalCapacityPrecise(gpa, growCapacity(self.buffer.len, new_capacity));
        }

        pub fn ensureTotalCapacityPrecise(self: *@This(), gpa: std.mem.Allocator, new_capacity: usize) std.mem.Allocator.Error!void {
            if (self.buffer.len >= new_capacity) return;
            const old_buffer = self.buffer;
            if (gpa.remap(old_buffer, new_capacity)) |new_buffer| {
                if (self.head > old_buffer.len - self.len) {
                    const head = new_buffer[self.head..old_buffer.len];
                    const tail = new_buffer[0 .. self.len - head.len];
                    if (head.len > tail.len and new_buffer.len - old_buffer.len > tail.len) {
                        @memcpy(new_buffer[old_buffer.len..][0..tail.len], tail);
                    } else {
                        self.head = new_buffer.len - head.len;
                        @memmove(new_buffer[self.head..][0..head.len], head);
                    }
                }
                self.buffer = new_buffer;
            } else {
                const new_buffer = try gpa.alloc(T, new_capacity);
                if (self.head < old_buffer.len - self.len) {
                    @memcpy(new_buffer[0..self.len], old_buffer[self.head..][0..self.len]);
                } else {
                    const head = old_buffer[self.head..];
                    const tail = old_buffer[0 .. self.len - head.len];
                    @memcpy(new_buffer[0..head.len], head);
                    @memcpy(new_buffer[head.len..][0..tail.len], tail);
                }
                self.head = 0;
                self.buffer = new_buffer;
                gpa.free(old_buffer);
            }
        }

        pub fn ensureUnusedCapacity(
            self: *@This(),
            gpa: std.mem.Allocator,
            additional_count: usize,
        ) std.mem.Allocator.Error!void {
            return self.ensureTotalCapacity(gpa, try addOrOom(self.len, additional_count));
        }

        pub fn pushBack(self: *@This(), gpa: std.mem.Allocator, item: T) error{OutOfMemory}!void {
            try self.ensureUnusedCapacity(gpa, 1);
            self.pushBackAssumeCapacity(item);
        }

        pub fn pushBackAssumeCapacity(self: *@This(), item: T) void {
            std.debug.assert(self.len < self.buffer.len);
            const buffer_index = self.bufferIndex(self.len);
            self.buffer[buffer_index] = item;
            self.len += 1;
        }

        pub fn front(self: *const @This()) ?T {
            if (self.len == 0) return null;
            return self.buffer[self.head];
        }

        pub fn popFront(self: *@This()) ?T {
            if (self.len == 0) return null;
            const pop_index = self.head;
            self.head = self.bufferIndex(1);
            self.len -= 1;
            return self.buffer[pop_index];
        }

        fn bufferIndex(self: *const @This(), index: usize) usize {
            const head_len = self.buffer.len - self.head;
            if (index < head_len) {
                return self.head + index;
            } else {
                return index - head_len;
            }
        }

        const init_capacity: comptime_int = @max(1, std.atomic.cache_line / @sizeOf(T));

        fn growCapacity(current: usize, minimum: usize) usize {
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum) return new;
            }
        }

        fn addOrOom(a: usize, b: usize) error{OutOfMemory}!usize {
            const result, const overflow = @addWithOverflow(a, b);
            if (overflow != 0) return error.OutOfMemory;
            return result;
        }
    };
}

pub fn panicFmt(comptime fmt: []const u8, args: anytype) noreturn {
    const size = 0x1000;
    const trunc_msg = "(msg truncated)";
    var buf: [size + trunc_msg.len]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0..size], fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => blk: {
            @memcpy(buf[size..], trunc_msg);
            break :blk &buf;
        },
    };
    @panic(msg);
}

fn enumTags(comptime T: type) []const u8 {
    const fields = @typeInfo(T).@"enum".fields;
    var result: [fields.len]u8 = undefined;
    for (&result, fields) |*r, f| r.* = f.value;
    const final = result;
    return &final;
}

fn short(comptime field: Opt) []const u8 {
    return "-" ++ std.fmt.comptimePrint("{c}", .{
        @intFromEnum(field),
    });
}

fn long(comptime field: Opt) []const u8 {
    return "--" ++ @tagName(field);
}

const Opt = @Type(.{
    .@"enum" = .{
        .tag_type = u8,
        .fields = @typeInfo(OptWith1Param).@"enum".fields ++ @typeInfo(OptWithoutParam).@"enum".fields,
        .decls = &.{},
        .is_exhaustive = false,
    },
});

const OptWith1Param = enum(u8) {
    const tags = enumTags(@This());

    fn is(str: []const u8) bool {
        inline for (@typeInfo(@This()).@"enum".fields) |field|
            if (std.mem.eql(u8, str, field.name[0..field.name.len])) return true;
        return false;
    }

    // TODO:
    // delimiters = 'd',
    // file = 'f',
    // @"jq-library-path" = 'j',
    // parameter = 'p',
};

const OptWithoutParam = enum(u8) {
    const tags = enumTags(@This());

    help = 'h',
    version = 'V',
};

pub const ArgIterator = struct {
    __allocator: std.mem.Allocator,
    __queue: Fifo([:0]const u8),
    __args: []const [:0]const u8,
    __i: usize,

    pub fn init(allocator: std.mem.Allocator, args: []const [:0]const u8) @This() {
        return .{
            .__allocator = allocator,
            .__queue = .empty,
            .__args = args,
            .__i = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        while (self.getQueue().len > 0) self.popFront();
        self.ptrQueue().deinit(self.getAllocator());
    }

    fn getAllocator(self: @This()) std.mem.Allocator {
        return self.__allocator;
    }

    fn getQueue(self: @This()) Fifo([:0]const u8) {
        return self.__queue;
    }

    fn ptrQueue(self: *@This()) *Fifo([:0]const u8) {
        return &self.__queue;
    }

    fn getArgs(self: @This()) []const [:0]const u8 {
        return self.__args;
    }

    fn getArg(self: @This(), i: usize) [:0]const u8 {
        return self.getArgs()[i];
    }

    fn getI(self: @This()) usize {
        return self.__i;
    }

    fn ptrI(self: *@This()) *usize {
        return &self.__i;
    }

    fn incrI(self: *@This()) void {
        self.ptrI().* += 1;
    }

    fn popFront(self: *@This()) void {
        std.debug.assert(self.getQueue().len > 0);
        self.getAllocator().free(self.getQueue().front().?);
    }

    fn append(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        std.debug.assert(self.getQueue().len < 2);
        try self.ptrQueue().pushBack(self.getAllocator(), try std.fmt.allocPrintSentinel(self.getAllocator(), fmt, args, 0));
    }

    // Handle '-abc' the same as '-a -bc' for short-form no-arg options
    fn handleContractedShortOptWithoutParam(self: *@This()) !void {
        var arg = if (self.getQueue().len > 0) self.getQueue().front().? else self.getArg(self.getI());

        if (!std.mem.startsWith(u8, arg, "-") or arg.len <= 2 or std.mem.indexOfAny(u8, arg[1..], OptWithoutParam.tags) != 0) return;

        var allocated = false;
        defer if (allocated) self.getAllocator().free(arg);
        if (self.getQueue().len > 0) {
            arg = try self.getAllocator().dupeZ(u8, self.getQueue().front().?);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{
            arg[0..2],
        });
        try self.append("-{s}", .{
            arg[2..],
        });
    }

    // Handle '-foo' the same as '-f oo' for short-form 1-arg options
    fn handleContractedShortOptWith1Param(self: *@This()) !void {
        var arg = if (self.getQueue().len > 0) self.getQueue().front().? else self.getArg(self.getI());

        if (!std.mem.startsWith(u8, arg, "-") or arg.len <= 2 or std.mem.indexOfAny(u8, arg[1..], OptWith1Param.tags) != 0) return;

        var allocated = false;
        defer if (allocated) self.getAllocator().free(arg);
        if (self.getQueue().len > 0) {
            arg = try self.getAllocator().dupeZ(u8, self.getQueue().front().?);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{
            arg[0..2],
        });
        try self.append("{s}", .{
            arg[2..],
        });
    }

    // Handle '--file=file1' the same as '--file file1' for long-form 1-arg options
    fn handleEqualLongOptWith1Param(self: *@This()) !void {
        var arg = if (self.getQueue().len > 0) self.getQueue().front().? else self.getArg(self.getI());
        const equal_index = std.mem.indexOfScalar(u8, arg, '=');

        if (!std.mem.startsWith(u8, arg, "--") or arg.len <= 3 or equal_index == null or !OptWith1Param.is(arg[2..equal_index.?])) return;

        var allocated = false;
        defer if (allocated) self.getAllocator().free(arg);
        if (self.getQueue().len > 0) {
            arg = try self.getAllocator().dupeZ(u8, self.getQueue().front().?);
            allocated = true;
            self.popFront();
        }

        try self.append("{s}", .{
            arg[0..equal_index.?],
        });
        if (arg[equal_index.? + 1 ..].len > 0) try self.append("{s}", .{
            arg[equal_index.? + 1 ..],
        });
    }

    pub fn next(self: *@This()) !?[:0]const u8 {
        if (self.getQueue().len == 2) {
            self.popFront();
        } else if (self.getQueue().len == 1) {
            self.popFront();
            self.incrI();
        }

        if (self.getI() >= self.getArgs().len and self.getQueue().len == 0) return null;

        try self.handleContractedShortOptWithoutParam();
        if (self.getQueue().len < 2) try self.handleContractedShortOptWith1Param();
        if (self.getQueue().len < 2) try self.handleEqualLongOptWith1Param();

        if (self.getQueue().len > 0) {
            return self.getQueue().front().?;
        } else {
            defer self.incrI();
            return self.getArg(self.getI());
        }
    }
};

fn emptyArg() void {
    @panic("Empty argument or parameter");
}

fn missingParam(arg: [:0]const u8) void {
    panicFmt("Missing mandatory parameter with {s} argument", .{
        arg,
    });
}

pub const Options = struct {
    __allocator: std.mem.Allocator,
    __help: bool,
    __version: bool,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .__allocator = allocator,
            .__help = false,
            .__version = false,
        };
    }

    pub fn deinit(_: *@This()) void {
        std.debug.print("TODO\n", .{});
    }

    fn getAllocator(self: @This()) std.mem.Allocator {
        return self.__allocator;
    }

    pub fn getHelp(self: @This()) bool {
        return self.__help;
    }

    pub fn getVersion(self: @This()) bool {
        return self.__version;
    }

    fn needHelp(self: *@This()) void {
        self.__help = true;
    }

    fn needVersion(self: *@This()) void {
        self.__version = true;
    }

    pub fn parse(self: *@This(), it: *ArgIterator) !void {
        _ = try it.next();
        while (try it.next()) |arg| {
            if (std.mem.eql(u8, arg, short(.help)) or std.mem.eql(u8, arg, long(.help))) {
                self.needHelp();
            } else if (std.mem.eql(u8, arg, short(.version)) or std.mem.eql(u8, arg, long(.version))) {
                self.needVersion();
            } else emptyArg();
        }
    }
};
