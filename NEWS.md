# NEWS

## v0.11.0

- Bars are lock-free, except for rendering.
- FPS cap to avoid wasting cycles.
- Exceptions thrown in progress loops now cause the bar to render where the failure occurred.
- Proper gutter-based rendering; stops trampling of old text.


## v0.11.1

- Fixed rendering/correctness bugs.
- Added support for interruption (via ctrl+C) and errors.
- `Base.length()` forwards to the underlying iterable.
- Loop/block context names use fresh lexical bindings. This covers inherited names and explicit names already declared outside workers; duplicate binding names are handled once.
- Macro-wrapped iteration bodies install and restore the active bar in the executing task, allowing bare `set_postfix!` calls in threaded and async-wrapped loops.
- Added `pbstatus` with `:running`, `:succeeded`, `:failed`, `:cancelled`, and `:interrupted` outcomes, plus `cancel!` for handles and iterator wrappers.
- Scoped/iterator bars no longer infer successful body completion from counter saturation. Macro loops observe exhaustion without wrapping the user's body in a closure; early `break`/`return` cancels the scope and retains partial counts.
- Scoped teardown cancels unfinished descendants, flushes best-effort, and releases the renderer. An abandoned child no longer prevents the original exception from reaching the caller.
- Failure bookkeeping is task-local, supports nested handlers/trees, and is separate from the 64-record display cap. Active milestones are recorded before their enclosing blocks, preserving the deepest frozen chain.
- SGR/OSC 8 styling is now supported.
