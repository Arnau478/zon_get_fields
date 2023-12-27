// MIT License
//
// Copyright (c) 2023 Alexei Kireev
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// zon_get_field is available from https://github.com/Durobot/zon_get_fields

const std = @import("std");

/// Limit on the length of the path, used by
/// `getFieldVal*` functions. These functions
/// call `walkAst`, which is a recursive function,
/// and `zon_fld_path_len_limit` is the recursion
/// depth limit.
const zon_fld_path_len_limit = 20;

const ZonParserError = error
{
    PathLimitReached,     // Field path contains to many elements (separated by dots), see `zon_fld_path_len_limit`
    BadSeparatorPosition, // Zero-length (empty) field path, separator (dot) at the beginning of the field path,
                          // at the end of the field path, or two consecutive dots in the path
    PathElementNotStruct, // One of the path elements (other than the last one) is not a sub-struct in ZON (AST)
    PathElementNotArray,  // One of the path elements (with [index]) is not an array in ZON (AST)
    BadArrIdxSyntax,      // Bad array index syntax in a field path element, e.g. one brace is missing,
    BadArrIdxValue,       // Bad array index syntax in a field path element, e.g. non-numeric character(s) in index,
                          // or the array doesn't contain enough elements
    NotFound,             // Field not found at the provided path
    BadBooleanValue,      // Field value could not be interpreted as a boolean, neither `false` nor `true`
    BadCharValue          // Field length is not 3, or field does not start or end with a quotation mark
};

/// Returns field value as a string - a slice of characters within `ast`.
/// This is the function used by all other `getFieldVal*` functions.
pub fn getFieldValStr(ast: std.zig.Ast, fld_path: []const u8) ![]const u8
{
    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const path_itr = std.mem.splitScalar(u8, fld_path, '.'); // SplitIterator(T, .scalar)
    const root_init = ast.fullStructInit(&buf, ast.nodes.items(.data)[0].lhs) orelse
    {
        std.log.warn("Zon parsing failed (top level struct)", .{});
        return ZonParserError.PathElementNotStruct;
    };
    // Compiler cantt understand path_itr is mutated, so its either
    // const path_itr + @constCast(&path_itr), or var path_itr + _ = &path_itr
    var str_val = try walkAst(ast, root_init.ast.fields, @constCast(&path_itr), 0);
    // Remove quotation marks if found
    if (str_val[0] == '"' and str_val[str_val.len - 1] == '"')
    {
        str_val.ptr += 1;
        str_val.len -= 2;
    }
    return str_val;
}

/// Returns field value as an integer
pub fn getFieldValInt(comptime T: type, ast: std.zig.Ast, fld_path: []const u8) !T
{
    const str_val = try getFieldValStr(ast, fld_path);
    // Autodetect the base, to allow hex, octa, etc.
    const int_val = try std.fmt.parseInt(T, str_val, 0);
    return int_val;
}

/// Returns field value as a float
pub fn getFieldValFloat(comptime T: type, ast: std.zig.Ast, fld_path: []const u8) !T
{
    const str_val = try getFieldValStr(ast, fld_path);
    const float_val = try std.fmt.parseFloat(T, str_val);
    return float_val;
}

/// Returns field value as a boolean
pub fn getFieldValBool(ast: std.zig.Ast, fld_path: []const u8) !bool
{
    const str_val = try getFieldValStr(ast, fld_path);
    if (std.mem.eql(u8, str_val, "true")) { return true; }
    else
    {
        if (std.mem.eql(u8, str_val, "false")) { return false; }
        else return ZonParserError.BadBooleanValue;
    }
}

/// Returns cahr field value as u8. Includes additional processing
/// (checking field format, removing quotaion marks) and does not
/// invoke `std.fmt.parseInt` unlike `getFieldValInt`.
pub fn getFieldValChar(ast: std.zig.Ast, fld_path: []const u8) !u8
{
    const str_val = try getFieldValStr(ast, fld_path);
    if (str_val.len == 1) return str_val[0];
    if (str_val.len != 3 or str_val[0] != '\'' or str_val[2] != '\'')
        return ZonParserError.BadCharValue;
    return str_val[1];
}

/// Meat and potatoes of the whole operation.
/// Goes through `ast_fields`, looking for the field referenced by
/// `path_itr.next()`. If `path_itr` contains no more elements after it,
/// returns field value, if it does, calls itself recursively.
/// In the end, returns the value of the field defined by `path_itr` as a
/// slice of characters within `ast` (a string), or an error.
fn walkAst(ast: std.zig.Ast,
           ast_fields: []const std.zig.Ast.Node.Index,
           path_itr: *std.mem.SplitIterator(u8, .scalar),
           recursion_depth: u32) ![]const u8
{
    const recursion_depth_2 = recursion_depth + 1;
    if (recursion_depth_2 > zon_fld_path_len_limit) // Limit recursion depth, for the sake of sanity
        return ZonParserError.PathLimitReached;

    // `path_element` is the current path element this function is going to handle.
    // There are 4 options:
    // 1. `path_element` is the last element of the path, and refers to a scalar field
    //    `walkAst()` returns the value of this field;
    // 2. `path_element` is the last element of the path, and refers to an array element (ends with [<idx>]),
    //    `walkAst()` returns the value of this array element;
    // 3. `path_element` is not the last element of the path, and refers to a struct,
    //    `walkAst()` recursively calls itself;
    // 4. `path_element` is not the last element of the path, and refers to an array element (ends with [<idx>])
    //    `walkAst()` recursively calls itself.
    var path_element = path_itr.next() orelse
    {
        std.log.warn("Ran out of path elements", .{});
        return ZonParserError.NotFound;
    };
    if (path_element.len == 0)
    {
        std.log.warn("Path starts with dot or zero-length path", .{});
        return ZonParserError.BadSeparatorPosition;
    }

    // If this path element is an array element, we must figure out the index (arr_idx)
    const arr_idx: ?std.zig.Ast.Node.Index = blk:
    {
        if (path_element[path_element.len - 1] == ']')
        {
            if (std.mem.lastIndexOfScalar(u8, path_element, '[')) |left_brace_pos|
            {
                const arr_idx = std.fmt.parseInt(std.zig.Ast.Node.Index,
                                                 path_element[(left_brace_pos+1)..(path_element.len-1)], 0) catch |err|
                {
                    std.log.warn("Bad array index value in {s}, {}", .{ path_element, err });
                    return ZonParserError.BadArrIdxValue;
                };
                path_element.len = left_brace_pos; // Make sure we ignore the array index part from now on
                break :blk arr_idx;
            }
            else
            {
                std.log.warn("Bad array index syntax in {s}", .{ path_element });
                return ZonParserError.BadArrIdxSyntax;
            }
        }
        break :blk null; // Index not found, `path_element` does NOT refer to an element of an array
    };

    const fld_idx = blk2:
    {
        if (path_element.len == 0) // Is this a pure index (no field name)?
        {
            if (arr_idx) |arr_idx_val|
            {
                if (arr_idx_val < 0 or arr_idx_val > ast_fields.len - 1)
                {
                    std.log.warn("Array index out of bounds - unnamed array contains {d} elements, index is {d}",
                                 .{ ast_fields.len, arr_idx_val });
                    return ZonParserError.BadArrIdxValue;
                }
                break :blk2 ast_fields[arr_idx_val];
            }
            // path_element.len == 0, but also arr_idx == null - empty path_element
            std.log.warn("Path ends with dot, or two dots in a row", .{});
            return ZonParserError.BadSeparatorPosition;
        }

        // path_element.len != 0, must find the field by name
        for (ast_fields) |fld_idx|
        {
            const fld_name = ast.tokenSlice(ast.firstToken(fld_idx) - 2);
            if (std.mem.eql(u8, path_element, fld_name))
                break :blk2 fld_idx;
        }

        std.log.warn("Path element '{s}' not found", .{ path_element });
        return ZonParserError.NotFound;
    };

    // --== Now, figure out what do we do with the field (fld_idx) we have found ==--
    //
    // If there's more in the path, must treat current field as either a (sub) struct, or an array
    if (path_itr.peek()) |nxt| // Could have used if (path_itr_2.index) |_|, but need `len` too
    {
        if (nxt.len == 0)
        {
            std.log.warn("Path ends with dot, or two dots in a row", .{});
            return ZonParserError.BadSeparatorPosition;
        }

        if (arr_idx) |arr_idx_val| // There's index in this `path_element`, treat it as an array
        {
            // -----------------------------------------------------
            // 4. `path_element` is not the last element of the path,
            //    and refers to an array element (ends with [<idx>])
            // -----------------------------------------------------
            const node_idx = blk3: // std.zig.Ast.Node.Index
            {
                if (path_element.len == 0) // Pure index, no field name
                {
                    if (arr_idx_val < 0 or arr_idx_val > ast_fields.len - 1)
                    {
                        std.log.warn("Array index out of bounds - anonymous arrys contains {d} elements, index is {d}",
                                     .{ ast_fields.len, arr_idx_val });
                        return ZonParserError.BadArrIdxValue;
                    }
                    break :blk3 ast_fields[arr_idx_val];
                }

                // If we got here, remaining part of this `path_element` is NOT empty,
                // which means we must get this array field's elements before we can return one of them
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const arr_init = ast.fullArrayInit(&buf, fld_idx) orelse // ?full.ArrayInit
                {
                    std.log.warn("Parsing of field '{s}' failed, or value is not an array", .{ path_element });
                    return ZonParserError.PathElementNotArray;
                };
                if (arr_idx_val < 0 or arr_idx_val > arr_init.ast.elements.len - 1)
                {
                    std.log.warn("Array index out of bounds - '{s}' contains {d} elements, index is {d}",
                                 .{ path_element, arr_init.ast.elements.len, arr_idx_val });
                    return ZonParserError.BadArrIdxValue;
                }
                break :blk3 arr_init.ast.elements[arr_idx_val];
            };

            // Peek at the next path element to figure out how we should treat array element -
            // as a struct or as an array
            if (nxt[nxt.len - 1] == ']') // Array element is an array too
            {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const arr_elt_arr_init = ast.fullArrayInit(&buf, node_idx) orelse
                {
                    std.log.warn("Parsing of field '{s}' failed, or its element {} is not an array",
                                .{ path_element, arr_idx_val });
                    return error.PathElementNotArray;
                };
                return walkAst(ast, arr_elt_arr_init.ast.elements, path_itr, recursion_depth_2);
            }
            else // Array element is a struct
            {
                var buf: [2]std.zig.Ast.Node.Index = undefined;
                const arr_elt_struct_init = ast.fullStructInit(&buf, node_idx) orelse
                {
                    std.log.warn("Parsing of element {} of array field '{s}' failed, or this element is not a struct",
                                .{ arr_idx_val, path_element });
                    return error.PathElementNotStruct;
                };
                return walkAst(ast, arr_elt_struct_init.ast.fields, path_itr, recursion_depth_2);
            }
        }
        else // No index in this `path_element`, treat it as a struct
        {
            // -----------------------------------------------------------------------------
            // 3. `path_element` is not the last element of the path, and refers to a struct
            // -----------------------------------------------------------------------------
            var buf: [2]std.zig.Ast.Node.Index = undefined;
            const substruct_init = ast.fullStructInit(&buf, fld_idx) orelse
            {
                std.log.warn("Parsing of field '{s}' failed, or value is not a struct", .{ path_element });
                return ZonParserError.PathElementNotStruct;
            };
            return walkAst(ast, substruct_init.ast.fields, path_itr, recursion_depth_2);
        }
    }
    else // --== No more path elements after this one, we have arrived, return the value ==--
    {
        // Get array element `arr_idx`, if any
        if (arr_idx) |arr_idx_val|
        {
            // -----------------------------------------------------
            // 2. `path_element` is the last element of the path,
            //    and refers to an array element (ends with [<idx>])
            //    so we treat it as a scalar value,
            //    and return as a string
            // -----------------------------------------------------

            // Is the remaining part of this `path_element` is empty, meaning
            // `ast_fields` already contains the list of array element indices?
            if (path_element.len == 0)
            {
                if (arr_idx_val < 0 or arr_idx_val > ast_fields.len - 1)
                {
                    std.log.warn("Array index out of bounds - anonymous arrys contains {d} elements, index is {d}",
                                 .{ ast_fields.len, arr_idx_val });
                    return ZonParserError.BadArrIdxValue;
                }
                return fulllTokenSlice(ast, ast.nodes.items(.main_token)[ast_fields[arr_idx_val]]);
            }

            // If we got here, remaining part of this `path_element` is NOT empty,
            // which means we must get this array field's elements before we can return one of them
            var buf: [2]std.zig.Ast.Node.Index = undefined;
            const arr_init = ast.fullArrayInit(&buf, fld_idx) orelse // ?full.ArrayInit
            {
                std.log.warn("Parsing of field '{s}' failed, or value is not an array", .{ path_element });
                return ZonParserError.PathElementNotArray;
            };
            if (arr_idx_val < 0 or arr_idx_val > arr_init.ast.elements.len - 1)
            {
                std.log.warn("Array index out of bounds - '{s}' contains {d} elements, index is {d}",
                             .{ path_element, arr_init.ast.elements.len, arr_idx_val });
                return ZonParserError.BadArrIdxValue;
            }

            const arr_elt_fld_idx = arr_init.ast.elements[arr_idx_val];
            return fulllTokenSlice(ast, ast.nodes.items(.main_token)[arr_elt_fld_idx]);
        }
        // -------------------------------------------------------------------------------
        // 1. `path_element` is the last element of the path, and refers to a scalar field
        // -------------------------------------------------------------------------------
        // `arr_idx` is null, return the field value as a scalar
        return fulllTokenSlice(ast, ast.nodes.items(.main_token)[fld_idx]);
    }
    // We MUST have returned either a value, or an error by this point
    unreachable;
}

/// Wrapper around `std.zig.Ast.tokenSlice()`, to get negative numbers properly
fn fulllTokenSlice(ast: std.zig.Ast, token_index: std.zig.Ast.TokenIndex) []const u8
{
    const ts = ast.tokenSlice(token_index);
    // Somehow for negative numbers (without quotation marks)
    // `Ast.tokenSlice` returns just the "-", so we must fix that.
    if (ts.len == 1 and ts[0] == '-')
    {
        // Ugly hack to get the correct slice
        var ts2 = ast.tokenSlice(token_index + 1);
        // We rely on the next tokenSlice being in `ast.source` right after
        // the one that is our "-".
        ts2.ptr -= 1;
        ts2.len += 1;
        return ts2;
    }
    return ts;
}

// ------------------ Tests ------------------

test "Top level struct parsing error test"
{
    const zon_txt =
        \\.{
        \\    .struct_1 =
        \\    {
        \\        .abc = "Hello",
        \\        .def = "you",
        \\    }
        \\}
        ;

    var ast = try std.zig.Ast.parse(std.testing.allocator, zon_txt, .zon);
    defer ast.deinit(std.testing.allocator);

    std.debug.print("\nDisregard the (warn) message below, it's normal:\n", .{});
    try std.testing.expectError(error.PathElementNotStruct, getFieldValStr(ast, "struct_1.abc"));
}

test "Big test"
{
    const zon_txt =
        \\.{
        \\    .ham = 0x11, // Hexadecimal is OK
        \\    .eggs = "1991", // Number in a string is OK, as long as it's valid
        \\    .bin = 0b10010110, // Binary is OK too
        \\    .foo = -1000,
        \\    .struct_1 =
        \\    .{
        \\        .abc = "Hello",
        \\        .def = "you",
        \\        .str_no_quotes = i_am_a_string_too, // Not a normal Zig string, but this works too
        \\        .float_cant_represent = 12.45, // See https://float.exposed , try this value
        \\        .float_negative = -10.0,
        \\        .recursion = .{ .depth = .{ .limit = .{ .check = .{ .six = .{ .seven = .{ .eight = .{ .nine = .{ .ten = .{ .l11 = .{ .l12 = .{ .l13 = .{ .l14 = .{ .l15 = .{ .l16 = .{ .l17 = .{ .l18 = .{ .l19 = .{ .l20 = .{ .l21 = "AHA!" }}}}}}}}}}}}}}}}}}},
        \\    },
        \\    .bool_1 = false,
        \\    .bool_2 = true,
        \\    .bool_str = "false",
        \\    .bool_bad = "dontknow",
        \\    .character_1 = 'A',
        \\    .character_no_quotes = B,
        \\    //.character_bad = 'a whole string!', - Makes Ast.parse() fail
        \\    .uint_arr = .{ 10, 20, 30, 40 }, // This is an array
        \\    .arr_struct =
        \\    .{
        \\        .{ .abc = 12, .def = 34 },
        \\        .{ .abc = 56, .def = 78 },
        \\        .{ .abc = 90, .def = 12 },
        \\    },
        \\    .arr_arr =
        \\    .{
        \\        .{ -11, -12, -13 },
        \\        .{  21,  22,  23 },
        \\        .{ -31, -32, -33 },
        \\    },
        \\    .arr_arr_struct =
        \\    .{
        \\        .{ .{ .q =  1, .w =  2 }, .{ .q =  3, .w =  4 }, .{ .q =  5, .w =  6 } },
        \\        .{ .{ .q =  7, .w =  8 }, .{ .q =  9, .w = 10 }, .{ .q = 11, .w = 12 } },
        \\        .{ .{ .q = 13, .w = 14 }, .{ .q = 15, .w = 16 }, .{ .q = 17, .w = 18 } },
        \\     },
        \\}
        ;
    var ast = try std.zig.Ast.parse(std.testing.allocator, zon_txt, .zon);
    defer ast.deinit(std.testing.allocator);

    std.debug.print("\nDisregard the (warn) messages below, they're normal:\n", .{});

    try std.testing.expectError(error.BadSeparatorPosition, getFieldValStr(ast, "struct_1..abc"));
    try std.testing.expectError(error.BadSeparatorPosition, getFieldValStr(ast, ".struct_1.abc"));
    try std.testing.expectError(error.BadSeparatorPosition, getFieldValStr(ast, "struct_1.abc."));
    try std.testing.expectError(error.PathElementNotArray, getFieldValStr(ast, "struct_1[0]"));
    try std.testing.expectError(error.PathElementNotStruct, getFieldValStr(ast, "arr_arr[0].abc"));
    try std.testing.expectError(error.BadArrIdxValue, getFieldValInt(u8, ast, "uint_arr[<bad index>]"));
    try std.testing.expectError(error.BadArrIdxSyntax, getFieldValInt(u8, ast, "uint_arr{2]"));

    // Assuming zon_fld_path_len_limit == 20
    try std.testing.expect(zon_fld_path_len_limit <= 20);
    // Otherwise this test makes no sense and must be adjusted accordingly
    try std.testing.expectError(error.PathLimitReached,
                                getFieldValStr(ast,
                                               "struct_1.recursion.depth.limit.check.six.seven.eight.nine.ten.l11.l12.l13.l14.l15.l16.l17.l18.l19.l20.l21"));

    var val_str = try getFieldValStr(ast, "ham");
    try std.testing.expectEqualStrings(val_str, "0x11");

    var val_u16 = try getFieldValInt(u16, ast, "ham");
    try std.testing.expectEqual(val_u16, 17);

    val_u16 = try getFieldValInt(u16, ast, "eggs");
    try std.testing.expectEqual(val_u16, 1991);
    //
    try std.testing.expectError(error.Overflow, getFieldValInt(u8, ast, "eggs"));

    var val_u8 = try getFieldValInt(u8, ast, "bin");
    try std.testing.expectEqual(val_u8, 0b10010110);

    const val_i16 = try getFieldValInt(i16, ast, "foo");
    try std.testing.expectEqual(val_i16, -1000);

    val_str = try getFieldValStr(ast, "foo");
    try std.testing.expectEqualStrings(val_str, "-1000");

    val_str = try getFieldValStr(ast, "struct_1.def");
    try std.testing.expectEqualStrings(val_str, "you");

    val_str = try getFieldValStr(ast, "struct_1.str_no_quotes");
    try std.testing.expectEqualStrings(val_str, "i_am_a_string_too");

    try std.testing.expectError(error.NotFound, getFieldValInt(u8, ast, "struct_1.bad_field"));

    // See https://float.exposed , https://www.h-schmidt.net/FloatConverter/IEEE754.html
    var val_float = try getFieldValFloat(f32, ast, "struct_1.float_cant_represent");
    try std.testing.expectEqual(val_float, 12.45);

    val_float = try getFieldValFloat(f32, ast, "struct_1.float_negative");
    try std.testing.expectEqual(val_float, -10.0);

    var val_bool = try getFieldValBool(ast, "bool_1");
    try std.testing.expect(!val_bool);
    //
    val_bool = try getFieldValBool(ast, "bool_2");
    try std.testing.expect(val_bool);
    //
    val_bool = try getFieldValBool(ast, "bool_str");
    try std.testing.expect(!val_bool);
    //
    try std.testing.expectError(error.BadBooleanValue, getFieldValBool(ast, "bool_bad"));

    val_u8 = try getFieldValChar(ast, "character_1");
    try std.testing.expectEqual(val_u8, 'A');
    //
    val_u8 = try getFieldValChar(ast, "character_no_quotes");
    try std.testing.expectEqual(val_u8, 'B');
    //
    try std.testing.expectError(error.BadCharValue, getFieldValChar(ast, "struct_1.str_no_quotes"));

    val_u8 = try getFieldValInt(u8, ast, "uint_arr[3]");
    try std.testing.expectEqual(val_u8, 40);
    //
    try std.testing.expectError(error.BadArrIdxValue, getFieldValInt(u8, ast, "uint_arr[4]"));

    val_u8 = try getFieldValInt(u8, ast, "arr_struct[2].abc");
    try std.testing.expectEqual(val_u8, 90);
    //
    try std.testing.expectError(error.NotFound, getFieldValInt(u8, ast, "arr_struct[2].not_there"));

    val_str = try getFieldValStr(ast, "arr_arr[2].[2]");
    try std.testing.expectEqualStrings(val_str, "-33");
    //
    const val_i8 = try getFieldValInt(i8, ast, "arr_arr[2].[2]");
    try std.testing.expectEqual(val_i8, -33);

    val_u8 = try getFieldValInt(u8, ast, "arr_arr_struct[2].[1].q");
    try std.testing.expectEqual(val_u8, 15);
}
