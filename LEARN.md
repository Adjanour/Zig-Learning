# Template Transpiler — Learning Walkthrough

## What we built

A **template transpiler**: it reads a file with embedded `<? ... ?>` code blocks and generates Zig source code that reproduces the same output at runtime.

Input (`index.html`):
```html
<h1><? greet(); ?></h1>
```

Output (generated Zig):
```zig
writer.WriteAll("<h1>");
greet();
writer.WriteAll("</h1>");
```

---

## The conceptual pattern: State Machine

The core pattern is a **two-state machine**. The program can be in exactly one of two modes at any time:

```
          ┌──────────────┐
   ┌─────►│  HTML mode   │◄─────┐
   │      │  (code=false) │     │
   │      └──────┬───────┘      │
   │             │              │
   │        sees "<?>"          │ sees "?>"
   │             │              │
   │      ┌──────▼───────┐      │
   └──────┤  Code mode   ├──────┘
          │  (code=true) │
          └──────────────┘
```

This is a fundamental pattern in computing:

- **Parsers / tokenizers** — scanning character by character
- **String interpolators** — switching between literal text and expression mode
- **Templating engines** (PHP, ERB, Jinja, JSX) — exactly this
- **Lexers** — grouping characters into tokens based on context

The key insight: **the same character can mean different things depending on the current state**. A `{` in HTML mode is just text; in code mode it's a block opener.

---

## The dual-buffer pattern

Why two `ArrayList(u8)`s?

| Buffer | Purpose | What goes in |
|---|---|---|
| `builder` | Scratch buffer | The current chunk being built (HTML or code) |
| `result` | Accumulator | The final generated source, built up over time |

```
                HTML chunks (escaped)
builder ─────────────────────────────────► result
  ▲                                           ▲
  │                                           │
  └── code chunks (verbatim) ─────────────────┘
```

`builder` gets **reused** — it collects characters until we hit a transition (`<?` or `?>`), then its contents are flushed to `result` and it resets to empty. This is the **accumulate-then-flush** pattern.

The flush happens via `toOwnedSlice`, which:
1. Returns the buffer's current contents as a `[]u8` slice
2. **Resets** the ArrayList to empty (capacity stays allocated, so future appends don't necessarily allocate)
3. Transfers ownership of the memory to the caller

---

## The Zig primitives used

### 1. `ArrayList(u8)` — dynamic byte buffer

```zig
var builder = std.ArrayList(u8).empty;
```

`.empty` creates an ArrayList with **no backing allocation**. The allocator is passed on every operation:

| Operation | What it does |
|---|---|
| `append(a, byte)` | Add one byte |
| `appendSlice(a, slice)` | Add many bytes |
| `toOwnedSlice(a)` | Take ownership of the buffer + reset to empty |
| `deinit(a)` | Free the allocation |

Why `u8`? Because we're building strings byte by byte.

### 2. `while` + manual index — character-by-character scanning

```zig
var i: usize = 0;
while (i < content.len) {
    const rest = content[i..];
    // ... use rest to check for "<?"
    // ... use content[i] for the current character
    i += 1; // or i += 2 when skipping "<?"
}
```

This is **imperative scanning**. We advance `i` manually based on what we find. The alternative would be iterators or slices, but manual indexing gives us fine-grained control over lookahead (`startsWith` on `rest`) and multi-character skip.

### 3. `content[i..]` — slicing for lookahead

```zig
const rest = content[i..];
```

This creates a **slice** (a view into the original array, no copy). We use it to check if the remaining text starts with a pattern:

```zig
if (std.mem.startsWith(u8, rest, CODE_START)) { ... }
```

This is equivalent to: "does the string starting at position `i` begin with `<?`?"

### 4. `std.mem.startsWith` — pattern matching

```zig
std.mem.startsWith(u8, slice, pattern)
```

Returns `true` if `slice` starts with `pattern`. Simple prefix check. We use it to detect the `<?` and `?>` delimiters.

### 5. `switch` on a `u8` — character dispatch

```zig
switch (content[i]) {
    '\n' => try builder.appendSlice(allocator, "\\n"),
    '\r' => try builder.appendSlice(allocator, "\\r"),
    ...
    else => try builder.append(allocator, content[i]),
}
```

A `switch` on a `u8` is the idiomatic way to handle character-by-character logic in Zig. It compiles to a jump table. The `else` arm catches everything not explicitly listed.

This is where the **escaping** happens — we replace special characters with their escaped representations so the output is a valid Zig string literal.

### 6. `try` — error propagation

Zig has no exceptions. Functions that can fail return a **union type** (`Error!ReturnType`). `try` unwraps it: if error, return it up the call stack; if success, give me the value.

Every `append`, `appendSlice`, `allocPrint`, and `toOwnedSlice` can fail (out of memory), so every call needs `try`.

### 7. `errdefer` — cleanup on error

```zig
errdefer builder.deinit(allocator);
errdefer result.deinit(allocator);
```

If any `try` in `main` propagates an error up, these run — freeing the two ArrayLists so we don't leak memory. This is Zig's equivalent of `defer`-but-only-on-error.

### 8. `std.fmt.allocPrint` — format into a string

```zig
try result.appendSlice(allocator, try std.fmt.allocPrint(allocator,
    "writer.WriteAll(\"{s}\");\n", .{html}));
```

This is like `sprintf` in C or `format!()` in Rust — it creates a new `[]u8` with the formatted text. The `{s}` is a format specifier that inserts the `html` slice. We then append that formatted string to `result`.

Note: `allocPrint` allocates a new string. This is wasteful in a tight loop — a streaming `writer` would be better — but fine for learning.

---

## The data flow, step by step

Take this input:
```
<h1><? greet(); ?></h1>
```

| i | char | mode | builder | action |
|---|---|---|---|---|
| 0 | `<` | HTML | `<` | append escaped |
| 1 | `h` | HTML | `<h` | append |
| ... | ... | HTML | `<h1>` | append |
| 4 | `?` | HTML | checks for `<?` | ... |
| 4 | `<` | HTML | `<h1>` (cont.) | no, it's `<` not `?` — wait, let me re-check |

Actually, let me re-trace with the actual code. At each iteration, we check `rest = content[i..]` for `<?`.

```
i=0: rest = "<h1><? greet(); ?></h1>"
     !code, rest doesn't start with "<?"
     → switch '<': append '<', i=1

i=1: rest = "h1><? greet(); ?></h1>"
     append 'h', i=2

i=2: append '1', i=3

i=3: append '>', i=4

i=4: rest = "<? greet(); ?></h1>"
     !code, rest starts with "<?"
     → flush builder ("<h1>") as writer.WriteAll("<h1>");
     → code=true, i=6

i=6: rest = " greet(); ?></h1>"
     code=true, rest doesn't start with "?>"
     → append ' ', i=7

i=7..14: append 'g','r','e','e','t','(','',';' — wait

i=15: rest = "?></h1>"
     code=true, rest starts with "?>"
     → flush builder (" greet(); ") verbatim
     → code=false, i=17

i=17: rest = "</h1>"
     !code, doesn't start with "<?"
     → append '<', i=18
     → append '/','h','1','>'
     → i=21 equals content.len, loop ends

After loop: !code, flush builder ("</h1>") as writer.WriteAll("</h1>");
```

Final result:
```
writer.WriteAll("<h1>");
 greet(); 
writer.WriteAll("</h1>");
```

(The leading space in ` greet(); ` comes from `<? greet(); ?>` — the space after `<?` and before `?>` is included verbatim. You could trim it if desired.)

---

## Mental model summary

| Concept | Zig mechanism |
|---|---|
| State | `var code: bool` flips on `<?` / `?>` |
| Character scanning | `while (i < content.len)` + manual `i += 1` |
| Lookahead | `const rest = content[i..]` + `std.mem.startsWith` |
| Accumulation | `ArrayList(u8)` with `.append` / `.appendSlice` |
| Flush & reset | `.toOwnedSlice(a)` returns contents + clears |
| Formatting | `std.fmt.allocPrint` to build formatted strings |
| Error handling | `try` everywhere, `errdefer` for cleanup |

The **state machine + accumulate-then-flush** pattern is universal. You'll see it in:
- Every template engine (Handlebars, ERB, Jinja, EJS)
- Every lexer/tokenizer (JSON parser, HTTP header parser)
- String interpolation (JavaScript template literals, C# `$""`)

The specific Zig primitives (`ArrayList`, `toOwnedSlice`, `switch` on `u8`, `try`, `allocPrint`) are the tools you used to express that pattern in Zig.

---

## Deep dive: Zig's memory model

Everything in this program ultimately comes down to **three concepts**:

```
           ┌──────────┐
           │ Allocator│  ← who gives you memory
           └────┬─────┘
                │
     ┌──────────┼──────────┐
     │          │          │
     ▼          ▼          ▼
  ArrayList   []u8      []u8  (slices)
  (growing)   (owner)   (view)
```

### Memory in Zig is explicit

Zig does not have a garbage collector, a borrow checker, or a reference counter. You **ask for memory** and you **return it**. There is no hidden allocation anywhere.

Every function that needs memory receives an `Allocator` parameter. There is no global malloc.

### `[]u8` — slices (the view into memory)

This is the single most important type to understand.

```zig
// A slice is two words: { ptr: [*]u8, len: usize }
const slice: []u8 = memory[0..10];
```

A `[]u8` is **not an array**. It's a **view** — a pointer + a length. Visually:

```
┌─────┬─────┐
│ ptr │ len │   ← []u8 (the slice itself lives on the stack)
└──┼──┴─────┘
   │
   ▼
┌───┬───┬───┬───┬───┬───┐
│   │   │   │   │   │   │   ← the actual bytes (live on the heap or somewhere else)
└───┴───┴───┴───┴───┴───┘
```

Two kinds of slices:

| Form | Meaning | Ownership |
|---|---|---|
| `[]u8` | Writable slice | Might own, might not |
| `[]const u8` | Read-only slice | You can only read, never write |

Our program uses `[]const u8` for `content` (the file we read — we don't need to modify it) and `[]u8` for the strings we build in ArrayLists.

**Slicing is free:**

```zig
const rest = content[i..];  // no copy, no allocation, O(1)
```

This just creates a new `{ptr, len}` pair pointing into the existing buffer. The underlying bytes don't move. This is why we can call it every iteration of the while loop.

### `content[i..content.len - i]` — why it was wrong

You originally wrote:
```zig
const s = content[i .. content.len - i];
```

If `content.len = 100` and `i = 10`:
- You want `content[10..100]` (90 bytes remaining)
- But `100 - 10 = 90`, so you get `content[10..90]` — you chopped off the last 10 bytes!

`a..b` in Zig means from index `a` **inclusive** to index `b` **exclusive**. The length of the result is `b - a`. So:
- `content[i..]` — from `i` to end `(= content.len)` — correct
- `content[i..content.len]` — same thing, explicit — also correct
- `content[i..content.len - i]` — off by one — wrong

---

## Allocators — where memory comes from

```zig
const allocator = init.arena.allocator();
```

An **allocator** is an object that can give you memory and take it back. In Zig it's an interface (a struct of function pointers):

```zig
const Allocator = struct {
    alloc: fn (self: *anyopaque, len: usize, ...) Error![]u8,
    free: fn (self: *anyopaque, bytes: []u8) void,
    // ... also resize, remap
};
```

Everything that allocates takes an `Allocator` parameter:

```zig
// allocPrint asks the allocator for a new buffer
const s = try std.fmt.allocPrint(allocator, "hello {s}", .{name});

// ArrayList asks the allocator when it needs to grow
try builder.append(allocator, 'x');
```

Different allocators for different jobs:

| Allocator | What it does | When to use |
|---|---|---|
| `arena` | Allocates, frees **everything at once** at the end | Short-lived programs, parsing |
| `page_allocator` | Asks the OS directly (mmap) | Large allocations |
| `heap.page_allocator` | General purpose | Day-to-day |
| `arena.allocator()` | Wraps another allocator, bulk-frees on reset | When you'd use arena in C |

Our program uses an **arena allocator** from `init.arena`. The arena allocates memory as we go, and when `main` returns, the arena frees everything in one shot. This is why we don't need to free individual allocations — the arena handles it.

(We still have `errdefer builder.deinit(allocator)` which would free the ArrayList's buffer manually if an error occurs before the arena cleans up — belt and suspenders.)

### What happens when you call `allocPrint`

```zig
try std.fmt.allocPrint(allocator, "writer.WriteAll(\"{s}\");\n", .{html});
```

1. `allocPrint` asks the allocator: "give me a buffer of roughly this size"
2. Allocator returns a `[]u8` (or an error)
3. `allocPrint` fills it with the formatted string
4. The caller (`result.appendSlice`) gets ownership of that `[]u8`
5. The `result` ArrayList copies the bytes into its own internal buffer
6. The temporary `[]u8` from `allocPrint` is **leaked** — we never free it!

Wait — is that a memory leak? Yes! `allocPrint` returns an owned slice, and we never free it. But because we're using an arena allocator, it will all be freed at once when `main` exits. For a short-lived program this is harmless. In a long-running server, you'd need to free each `allocPrint` result.

---

## ArrayList internals — what's inside the box

```zig
const ArrayList(T) = struct {
    items: []T,       // the slice of used elements
    capacity: usize,  // how many elements fit before reallocation
    // (allocator is NOT stored — passed to each method in the .empty variant)
};
```

Memory layout after appending `'h'`, `'e'`, `'l'`, `'l'`, `'o'`:

```
items.ptr ──► ┌───┬───┬───┬───┬───┬───┬───┬───┐
              │ h │ e │ l │ l │ o │   │   │   │
              └───┴───┴───┴───┴───┴───┴───┴───┘
              ├─── items.len = 5 ──┤
              ├──── capacity = 8 ──────────┤
```

When you call `append(allocator, 'x')` and `items.len == capacity`:
1. Allocate a new buffer (typically 2x the old capacity)
2. Copy old items to new buffer
3. Free old buffer
4. Append the new element

This is the standard **dynamic array** / `std::vector` / `ArrayList` pattern.

### `.empty` — the trick

```zig
var builder = std.ArrayList(u8).empty;
```

This creates an ArrayList where `items = &[0]u8` (pointer to a zero-length slice) and `capacity = 0`. No allocation has happened yet. The first `append` will allocate.

Why does this exist? Because in Zig, you can't have an ArrayList without knowing the allocator at construction time **unless** you pass the allocator to every method. `.empty` gives you a zero-cost starting point.

Before `.empty` existed, you had to write:

```zig
var builder = std.ArrayList(u8).init(allocator);
builder.append('x');  // no allocator arg — stored in the struct
```

The new style (`.empty` + pass allocator everywhere) and the old style (`.init(a)` + allocator stored internally) both work. We're using the new style.

### `toOwnedSlice` — the flush

```zig
const html = try builder.toOwnedSlice(allocator);
```

What happens internally:
1. Shrink the allocation so `capacity == items.len` (no waste)
2. Return `items` to the caller (transfer ownership)
3. Reset to `items = &[0]u8, capacity = 0` (empty again)

After this, `builder` is fresh. You can start appending to it again, and it will allocate anew.

---

## `io` — where does it come from?

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
```

In standard Zig, `main` takes `void` or `[]u8` (command line args). The `std.process.Init` pattern is a newer API (Zig nightly / 0.14+) that bundles:

```zig
pub const Init = struct {
    io: Io,          // I/O abstraction (stdin/stdout/stderr/files)
    arena: Arena,    // arena allocator
    args: [][]u8,    // command line arguments
};
```

It's a convenience — instead of calling `std.io.getStdOut()`, `std.heap.page_allocator`, etc., you get them all in one struct.

The `io` value has methods like:
- `io.reader(...)` — read from stdin
- `io.writer(...)` — write to stdout
- `Dir.cwd().readFileAlloc(io, ...)` — read a file (the `io` is passed for error context)

This is Zig's **compile-time I/O abstraction**. `Io` is typically a comptime generic parameter that resolves to either a real OS I/O or a test/fake I/O. The `io` value passed around enables this without hard-coding OS calls everywhere.

---

## Putting it all together: memory flow diagram

```
                          Arena allocator
                               │
         ┌─────────────────────┼─────────────────────┐
         │                     │                     │
         ▼                     ▼                     ▼
    readFileAlloc          allocPrint            ArrayList.append
         │                     │                     │
         ▼                     ▼                     ▼
    content: []u8        temp: []u8             builder.items: []u8
    (owned by us)        (leaked until         (managed by ArrayList)
                           arena free)
                               │
                          appendSlice
                               │
                               ▼
                         result.items: []u8
                         (managed by ArrayList)
                               │
                          toOwnedSlice
                               │
                               ▼
                         output: []u8
                         (printed, then arena-freed)
```

Every arrow is an allocator call. Every `[]u8` exists somewhere in memory, pointed to by a slice. The arena sits at the root, and when `main` exits, everything is freed at once.

---

## Summary table: the primitives

| Primitive | It is... | Mental model |
|---|---|---|
| `[]u8` | A `{ptr, len}` pair | A **view** into some bytes, not the bytes themselves |
| `[]const u8` | A read-only view | "I promise not to mutate this" |
| `Allocator` | A `{alloc, free}` function table | The **plumber** who gives and takes memory |
| `ArrayList(T)` | A dynamic array `{items, capacity}` | A **growing buffer** that manages its own memory |
| `toOwnedSlice` | Transfer + reset | "Take my buffer, I'm done with it" |
| `arena` | Bulk-alloc, bulk-free | A **scratch pad** — use for short-lived programs |
| `try` | Unwrap-or-return | "If this fails, bail out" |
| `errdefer` | Defer-on-error-only | "Clean up only if something went wrong" |
| `Io` | I/O abstraction | A **handle** to read files, write output, etc. |
