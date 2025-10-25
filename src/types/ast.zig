const std = @import("std");
const TokenType = @import("token").TokenType;

pub const Program = struct {
    expressions: []Expr,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Program) void {
        for (self.expressions) |*e| {
            e.deinit(self.allocator);
        }

        self.allocator.free(self.expressions);
    }
};

// In ast.zig
pub fn freeExpr(expr: *Expr, allocator: std.mem.Allocator) void {
    switch (expr.*) {
        .binary => |bin| {
            freeExpr(bin.left, allocator);
            freeExpr(bin.right, allocator);
            allocator.destroy(bin.left);
            allocator.destroy(bin.right);
        },
        .ok_expr => |ok_e| {
            freeExpr(ok_e.value, allocator);
            allocator.destroy(ok_e.value);
        },
        .err_expr => |err_e| {
            freeExpr(err_e.message, allocator);
            allocator.destroy(err_e.message);
        },
        .literal, .identifier => {},
        // Add other expression types...
    }
}

pub fn freeProgram(program: []Expr, allocator: std.mem.Allocator) void {
    for (program) |*expr| {
        freeExpr(expr, allocator);
    }
    allocator.free(program);
}

pub const Expr = union(enum) {
    literal: Literal,
    identifier: []const u8,
    binary: BinaryExpr,
    unary: UnaryExpr,
    ok_expr: OkExpr,
    err_expr: ErrExpr,
    assignment: AssignExpr,
    policy: Policy,
    pipe: PipeExpr,
    // Add these if they exist in your code:
    list: ListExpr,
    map: MapExpr,
    lambda: LambdaExpr,
    call: CallExpr,
    try_expr: TryExpr,
    match_expr: MatchExpr,
    or_expr: OrExpr,
    then_expr: ThenExpr,
    tap_expr: TapExpr,

    /// Recursively free all heap allocations in this expression tree
    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .assignment => |a| {
                a.value.deinit(allocator);
                allocator.destroy(a.value);
            },
            .binary => |b| {
                b.left.deinit(allocator);
                b.right.deinit(allocator);
                allocator.destroy(b.left);
                allocator.destroy(b.right);
            },
            .unary => |u| {
                u.operand.deinit(allocator);
                allocator.destroy(u.operand);
            },
            .ok_expr => |ok| {
                ok.value.deinit(allocator);
                allocator.destroy(ok.value);
            },
            .err_expr => |err| {
                err.message.deinit(allocator);
                allocator.destroy(err.message);
            },
            .policy => |p| {
                p.expr.deinit(allocator);
                allocator.destroy(p.expr);
            },
            .pipe => |p| {
                p.left.deinit(allocator);
                p.right.deinit(allocator);
                allocator.destroy(p.left);
                allocator.destroy(p.right);
            },
            .list => |l| {
                for (l.elements) |*elem| {
                    elem.deinit(allocator);
                }
                allocator.free(l.elements);
            },
            .map => |m| {
                for (m.pairs) |*pair| {
                    pair.value.deinit(allocator);
                }
                allocator.free(m.pairs);
            },
            .lambda => |lam| {
                lam.body.deinit(allocator);
                allocator.destroy(lam.body);
                // Note: params are string slices owned by tokens, don't free
            },
            .call => |c| {
                c.callee.deinit(allocator);
                allocator.destroy(c.callee);
                for (c.args) |*arg| {
                    arg.deinit(allocator);
                }
                allocator.free(c.args);
            },
            .try_expr => |t| {
                t.expr.deinit(allocator);
                allocator.destroy(t.expr);
            },
            .match_expr => |m| {
                m.value.deinit(allocator);
                allocator.destroy(m.value);
                for (m.branches) |*branch| {
                    branch.expr.deinit(allocator);
                    allocator.destroy(branch.expr);
                }
                allocator.free(m.branches);
            },
            .or_expr => |o| {
                o.left.deinit(allocator);
                o.right.deinit(allocator);
                allocator.destroy(o.left);
                allocator.destroy(o.right);
            },
            .then_expr => |t| {
                t.left.deinit(allocator);
                t.right.deinit(allocator);
                allocator.destroy(t.left);
                allocator.destroy(t.right);
            },
            .tap_expr => |t| {
                t.left.deinit(allocator);
                t.right.deinit(allocator);
                allocator.destroy(t.left);
                allocator.destroy(t.right);
            },
            // Leaf nodes - no heap allocations to free
            .literal => {},
            .identifier => {},
        }
    }
};

pub const Type = enum { number, string, boolean, none, unknown };

pub const OkExpr = struct {
    value: *Expr, // The value to wrap
};

pub const ErrExpr = struct {
    message: *Expr, // The error message (should eval to string)
};

pub const PolicyValue = enum {
    none,
    panic_on_error, // !
    keep_wrapped, // ^
    unwrap_or_none, // ?
};

pub const Policy = struct {
    policy: PolicyValue,
    expr: *Expr,
};

pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    none: void,
};

pub const UnaryExpr = struct {
    operator: TokenType,
    operand: *Expr,
};

pub const MapExpr = struct {
    pairs: []MapPair,
};

pub const MapPair = struct {
    key: []const u8,
    value: Expr,
};

pub const ListExpr = struct {
    elements: []Expr,
};

pub const LambdaExpr = struct {
    params: [][]const u8,
    body: *Expr,
};

pub const OrExpr = struct {
    left: *Expr,
    // binding: [][]const u8, why is there a binding???
    right: *Expr,
};

pub const ThenExpr = struct {
    left: *Expr,
    // binding: [][]const u8, why is there a binding???
    right: *Expr,
};

pub const TapExpr = struct {
    left: *Expr,
    binding: [][]const u8,
    right: *Expr,
};

pub const BinaryExpr = struct {
    left: *Expr,
    operator: TokenType, // e.g. .PLUS, .OR
    right: *Expr,
};

pub const CallExpr = struct {
    callee: *Expr, // e.g. @File.read
    args: []Expr,
};

pub const AssignExpr = struct {
    name: []const u8,
    type: ?Type,
    value: *Expr,
};

pub const PipeExpr = struct {
    left: *Expr,
    right: *Expr,
};

pub const TryExpr = struct {
    expr: *Expr,
};

pub const MatchExpr = struct {
    value: *Expr,
    branches: []MatchBranch,
};

pub const MatchBranch = struct {
    pattern: []const u8,
    binding: [][]const u8,
    expr: *Expr,
};

fn indent(depth: usize) void {
    // print two spaces per depth; no buffers, no aliasing
    for (0..depth) |_| std.debug.print("  ", .{});
}

pub fn printExpr(expr: Expr, depth: usize) void {
    _ = struct {
        fn run(d: usize) void {
            var i: usize = 0;
            while (i < d) : (i += 1) std.debug.print("  ", .{});
        }
    }.run;

    switch (expr) {
        .identifier => |name| {
            indent(depth);
            std.debug.print("Identifier: {s}\n", .{name});
        },

        .literal => |lit| switch (lit) {
            .string => |s| {
                indent(depth);
                std.debug.print("String: \"{s}\"\n", .{s});
            },
            .number => |n| {
                indent(depth);
                std.debug.print("Number: {d}\n", .{n});
            },
            .boolean => |b| {
                indent(depth);
                std.debug.print("Boolean: {}\n", .{b});
            },
            .none => {
                indent(depth);
                std.debug.print("None\n", .{});
            },
        },

        .list => |items| {
            indent(depth);
            std.debug.print("List:\n", .{});
            for (items) |item| printExpr(item, depth + 1);
        },

        .map => |pairs| {
            indent(depth);
            std.debug.print("Map:\n", .{});
            for (pairs) |p| {
                indent(depth + 1);
                std.debug.print("{s} :\n", .{p.key});
                printExpr(p.value.*, depth + 2);
            }
        },

        .assign => |a| {
            indent(depth);
            std.debug.print("Assign:\n", .{});
            indent(depth + 1);
            std.debug.print("name: {s}\n", .{a.name});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            printExpr(a.value.*, depth + 2);
        },

        .pipe => |p| {
            indent(depth);
            std.debug.print("Pipe\n", .{});
            indent(depth + 1);
            std.debug.print("├── left\n", .{});
            printExpr(p.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("└── right\n", .{});
            printExpr(p.right.*, depth + 2);
        },

        .tap_expr => |t| {
            indent(depth);
            std.debug.print("TapExpr\n", .{});
            indent(depth + 1);
            std.debug.print("├── left\n", .{});
            printExpr(t.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("├── binding(s): ", .{});
            for (t.binding, 0..) |b, i| {
                if (i != 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{b});
            }
            std.debug.print("\n", .{});
            indent(depth + 1);
            std.debug.print("└── right\n", .{});
            printExpr(t.right.*, depth + 2);
        },

        .binary => |b| {
            indent(depth);
            std.debug.print("Binary\n", .{});
            indent(depth + 1);
            std.debug.print("left:\n", .{});
            printExpr(b.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("operator: {any}\n", .{b.operator});
            indent(depth + 1);
            std.debug.print("right:\n", .{});
            printExpr(b.right.*, depth + 2);
        },

        .call => |c| {
            indent(depth);
            std.debug.print("Call\n", .{});
            indent(depth + 1);
            std.debug.print("├── callee\n", .{});
            printExpr(c.callee.*, depth + 2);
            indent(depth + 1);
            std.debug.print("└── args\n", .{});
            for (c.args, 0..) |arg, i| {
                indent(depth + 2);
                std.debug.print("arg[{d}]:\n", .{i});
                printExpr(arg, depth + 3);
            }
        },

        .try_expr => |te| {
            indent(depth);
            std.debug.print("Try\n", .{});
            printExpr(te.expr.*, depth + 1);
        },

        .match_expr => |m| {
            indent(depth);
            std.debug.print("Match\n", .{});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            printExpr(m.value.*, depth + 2);
            indent(depth + 1);
            std.debug.print("branches:\n", .{});
            for (m.branches) |br| {
                indent(depth + 2);
                std.debug.print("pattern: {s}", .{br.pattern});
                if (br.binding) |b| std.debug.print("({s})", .{b});
                std.debug.print("\n", .{});
                printExpr(br.expr.*, depth + 3);
            }
        },

        .lambda => |l| {
            indent(depth);
            std.debug.print("Lambda\n", .{});
            indent(depth + 1);
            std.debug.print("params: ", .{});
            for (l.params, 0..) |p, i| {
                if (i != 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{p});
            }
            std.debug.print("\n", .{});
            indent(depth + 1);
            std.debug.print("body:\n", .{});
            printExpr(l.body.*, depth + 2);
        },
    }
}

pub fn debugPrint(expr: Expr, depth: usize) void {
    _ = struct {
        fn run(d: usize) void {
            var i: usize = 0;
            while (i < d) : (i += 1) std.debug.print("  ", .{});
        }
    }.run;

    switch (expr) {
        .literal => |lit| switch (lit) {
            .number => {
                indent(depth);
                std.debug.print("Number: {}\n", .{lit.number});
            },
            .string => {
                indent(depth);
                std.debug.print("String: \"{s}\"\n", .{lit.string});
            },
            .boolean => {
                indent(depth);
                std.debug.print("Bool: {}\n", .{lit.boolean});
            },
            .none => {
                indent(depth);
                std.debug.print("None\n", .{});
            },
        },

        .map => |map| {
            indent(depth);
            std.debug.print("Map:\n", .{});
            for (map.pairs) |m| {
                indent(depth + 1);
                std.debug.print("{s} :\n", .{m.key});
                debugPrint(m.value, depth + 2);
            }
        },

        .list => |items| {
            indent(depth);
            std.debug.print("List:\n", .{});
            for (items.elements) |item| debugPrint(item, depth + 1);
        },

        .identifier => {
            indent(depth);
            std.debug.print("Identifier: {s}\n", .{expr.identifier});
        },

        .assign => |a| {
            indent(depth);
            std.debug.print("Assign:\n", .{});
            indent(depth + 1);
            std.debug.print("name: {s}\n", .{a.name});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            debugPrint(a.value.*, depth + 2);
        },

        .pipe => |p| {
            indent(depth);
            std.debug.print("Pipe\n", .{});
            indent(depth + 1);
            std.debug.print("├── left\n", .{});
            debugPrint(p.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("└── right\n", .{});
            debugPrint(p.right.*, depth + 2);
        },

        .tap_expr => |t| {
            indent(depth);
            std.debug.print("TapExpr\n", .{});
            indent(depth + 1);
            std.debug.print("├── left\n", .{});
            debugPrint(t.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("├── binding(s): ", .{});
            for (t.binding, 0..) |b, i| {
                if (i != 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{b});
            }
            std.debug.print("\n", .{});
            indent(depth + 1);
            std.debug.print("└── right\n", .{});
            debugPrint(t.right.*, depth + 2);
        },

        .binary => |b| {
            indent(depth);
            std.debug.print("Binary\n", .{});
            indent(depth + 1);
            std.debug.print("left:\n", .{});
            debugPrint(b.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("operator: {any}\n", .{b.operator});
            indent(depth + 1);
            std.debug.print("right:\n", .{});
            debugPrint(b.right.*, depth + 2);
        },

        .call => |c| {
            indent(depth);
            std.debug.print("Call\n", .{});
            indent(depth + 1);
            std.debug.print("├── callee\n", .{});
            debugPrint(c.callee.*, depth + 2);
            if (c.args.len > 0) {
                indent(depth + 1);
                std.debug.print("└── args\n", .{});
                for (c.args, 0..) |arg, i| {
                    indent(depth + 2);
                    std.debug.print("arg[{d}]:\n", .{i});
                    debugPrint(arg, depth + 3);
                }
            }
        },

        .try_expr => |te| {
            indent(depth);
            std.debug.print("Try\n", .{});
            indent(depth + 1);
            std.debug.print("expr:\n", .{});
            debugPrint(te.expr.*, depth + 2);
        },

        .match_expr => |m| {
            indent(depth);
            std.debug.print("Match\n", .{});
            indent(depth + 1);
            std.debug.print("value:\n", .{});
            debugPrint(m.value.*, depth + 2);
            indent(depth + 1);
            std.debug.print("branches:\n", .{});
            for (m.branches) |br| {
                indent(depth + 2);
                std.debug.print("pattern: {s}", .{br.pattern});
                for (br.binding, 0..) |b, i| {
                    std.debug.print("{s}", .{b});
                    if (i + 1 < br.binding.len) std.debug.print(", ", .{});
                }
                if (br.binding.len == 0) std.debug.print("(no bindings)", .{});
                std.debug.print("\n", .{});
                debugPrint(br.expr.*, depth + 3);
            }
        },

        .lambda => |lam| {
            indent(depth);
            std.debug.print("Lambda:\n", .{});
            indent(depth + 1);
            std.debug.print("params: ", .{});
            for (lam.params, 0..) |p, i| {
                if (i != 0) std.debug.print(", ", .{});
                std.debug.print("{s}", .{p});
            }
            std.debug.print("\n", .{});
            indent(depth + 1);
            std.debug.print("body:\n", .{});
            debugPrint(lam.body.*, depth + 2);
        },

        .or_expr => |o| {
            indent(depth);
            std.debug.print("Or\n", .{});
            indent(depth + 1);
            std.debug.print("left:\n", .{});
            debugPrint(o.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("right:\n", .{});
            debugPrint(o.right.*, depth + 2);
        },

        .then_expr => |a| {
            indent(depth);
            std.debug.print("And\n", .{});
            indent(depth + 1);
            std.debug.print("left:\n", .{});
            debugPrint(a.left.*, depth + 2);
            indent(depth + 1);
            std.debug.print("right:\n", .{});
            debugPrint(a.right.*, depth + 2);
        },
    }
}
