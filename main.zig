const std = @import("std");

// Define the Op codes ( Instruction set )
const Op = enum(u8) { push, add, sub, mul, div, print, halt };

const Stack = struct {
    data: [256]i64,
    sp: usize,

    pub fn push(self: *Stack, value: i64) void {
        self.data[self.sp] = value;
        self.sp += 1;
    }

    pub fn pop(self: *Stack) i64 {
        self.sp -= 1;
        return self.data[self.sp];
    }

    pub fn peek(self: *Stack) i64 {
        return self.data[self.sp - 1];
    }
};

// program state
const VM = struct {
    stack: Stack,

    program: []const u8,
    ip: usize,
};

const program = [_]u8{ @intFromEnum(Op.push), 2, @intFromEnum(Op.push), 3, @intFromEnum(Op.add), @intFromEnum(Op.print), @intFromEnum(Op.halt) };

pub fn main() !void {
    var vm = VM{
        .stack = Stack{ .data = std.mem.zeroes([256]i64), .sp = 0 },
        .program = &program,
        .ip = undefined,
    };

    // core loop
    // read instruction
    // decode instruction
    // execute
    // advance the ip

    // initialize ip to zero start of instruction
    vm.ip = 0;

    while (true) {
        // read instruction from program
        const op: Op = @enumFromInt(vm.program[vm.ip]);
        vm.ip += 1;

        // decode instruction
        switch (op) {
            .push => {
                const value = vm.program[vm.ip];
                vm.ip += 1;

                vm.stack.push(value);
            },
            .add => {
                // get two operands form stack and add
                const a = vm.stack.pop();
                const b = vm.stack.pop();

                vm.stack.push(a + b);
            },
            .mul => {
                // get two operands form stack and add
                const a = vm.stack.pop();
                const b = vm.stack.pop();

                vm.stack.push(a * b);
            },
            .div => {
                // get two operands form stack and add
                const a = vm.stack.pop();
                const b = vm.stack.pop();

                vm.stack.push(@divFloor(a, b));
            },
            .print => {
                // get result from stack using stack pointer and print
                const value = vm.stack.pop();
                std.debug.print("Result:{d}\n", .{value});
            },
            .halt => {
                break;
            },
            else => {
                break;
            },
        }
    }
}
