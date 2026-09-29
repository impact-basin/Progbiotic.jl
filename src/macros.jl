function _is_macrocall_progress(e)
    if e isa Expr && e.head == :macrocall
        mname = e.args[1]
        return mname == Symbol("@progress") ||
               (mname isa Expr && mname.head == :. && mname.args[end] == QuoteNode(Symbol("@progress")))
    end
    return false
end

function _extract_macrocall_args(e)
    return filter(a -> !(a isa LineNumberNode), e.args[2:end])
end

function _parse_progress_item(item, res::Dict{Symbol, Any})
    if item isa String
        res[:desc] = item
    elseif item isa Symbol
        # Theme symbol (e.g. AMBER, GLACIER, NEON)
        res[:theme] = item
    elseif item isa Expr
        if item.head == :call && item.args[1] == :(=>)
            # pair binding: (pbar => args...)
            res[:bind] = item.args[2]
            _parse_progress_item(item.args[3], res)
        elseif item.head == :tuple
            for elem in item.args
                _parse_progress_item(elem, res)
            end
        elseif item.head == :(=) || item.head == :kw
            # keyword form (full name or short alias, e.g. `final_depth=1` or `d=1`)
            key, val = item.args[1], item.args[2]
            key, val = _canonical_progress_option(key, val)
            res[key] = val
        elseif item.head == :string # Interpolated string
            res[:desc] = item
        else
            res[:theme] = item
        end
    end
end

"""
    _coerce_final_depth(val) -> Int

Normalises a `final_depth` value to an `Int`. Dynamic expressions (symbols etc.) are
passed through unchanged and resolved at runtime.
"""
function _coerce_final_depth(val)
    val isa Integer && return Int(val)
    if val isa Real
        val == round(val) || error("@progress: `final_depth` must be an integer, got $(repr(val))")
        return Int(val)
    end
    return val
end

"""
    _canonical_progress_option(key, val) -> (canonical_key, val)

Maps short-form option names to their full names and normalises values:
- `d=1`     -> `final_depth=1`
- `t=OCEAN` -> `theme=OCEAN`
- `v=false` -> `vanish=false`      (keep bars on screen)
- `v=1.2`   -> `vanish_timeout=1.2` (seconds)
- `vanish=2.0` -> `vanish_timeout=2.0` (seconds; also the log lines' lifetime)
- `capture=[:warn, :error]` -> `capture_logs=[:warn, :error]` (log interception)
"""
function _canonical_progress_option(key, val)
    if key === :d
        return (:final_depth, _coerce_final_depth(val))
    elseif key === :t
        return (:theme, val)
    elseif key === :v
        if val isa Bool
            return (:vanish, val)
        elseif val isa Real
            return (:vanish_timeout, float(val))
        else
            error("@progress: `v=$val` is ambiguous — use `vanish=<bool>` (e.g. `v=false` keeps bars on screen) or `vanish_timeout=<seconds>` (e.g. `v=1.2`)")
        end
    elseif key === :vanish_timeout && val isa Real
        # normalise e.g. `vanish_timeout=1` to Float64 for add_job!
        return (:vanish_timeout, float(val))
    elseif key === :vanish && val isa Real
        # `vanish=2.0` is the numeric form of `vanish_timeout=2.0`: the timeout
        # applies to both the bar and the log lines it holds.
        return (:vanish_timeout, float(val))
    elseif key === :capture || key === :capture_logs
        # which log levels are intercepted (`true`/`false`, a LogLevel, or a
        # collection of levels/symbols). A macro-level option: it is never
        # forwarded to `add_job!`.
        return (:capture_logs, val)
    elseif key === :final_depth
        return (:final_depth, _coerce_final_depth(val))
    elseif key === :threads
        error("@progress: the `threads=true` option was removed — wrap the loop with `Threads.@threads` instead, e.g. `@progress \"desc\" Base.Threads.@threads for i in 1:100 ... end`")
    end
    return (key, val)
end

function _parse_progress_args(args)
    res = Dict{Symbol, Any}(
        :bind           => nothing,
        :desc           => "",
        :theme          => :(Progbiotic.AMBER),
        :title          => "",
        :vanish         => nothing,
        :vanish_timeout => nothing,
        :final_depth    => 0,
        :with           => nothing,
        :spinner        => nothing,
        :barunits       => nothing,
        :empty          => nothing,
        :caps           => nothing,
        :head           => nothing,
        :width          => nothing,
        :capture_logs   => nothing,
        :log_file       => nothing,
        :io             => nothing,
    )
    # A bare symbol as the first argument binds a context variable:
    # `@progress ctx "desc" ...` is shorthand for `@progress (ctx => "desc") ...`.
    if !isempty(args) && args[1] isa Symbol
        res[:bind] = args[1]
        args = args[2:end]
    end
    for arg in args
        _parse_progress_item(arg, res)
    end
    return res
end

# the glyph and width keywords, forwarded to the node constructor when set.
function _extract_extra_kws(opts)
    kws = Any[]
    for key in (:spinner, :barunits, :empty, :caps, :head, :width)
        opts[key] !== nothing && push!(kws, Expr(:kw, key, opts[key]))
    end
    return kws
end

# the vanish pair, always passed explicitly even when the level set neither. The two
# constructors read its absence differently: a root keeps its own bar for the whole scope
# while a child takes the tree's child default.
_vanish_kws(opts) = Any[Expr(:kw, :vanish, opts[:vanish]),
                        Expr(:kw, :vanish_timeout, opts[:vanish_timeout])]

_contains_for(e) =
    e isa Expr && (e.head == :for ||
                   (e.head == :macrocall && any(_contains_for, e.args[2:end])))

"""
    _unwrap_loop(expr) -> (for_expr, wrappers)

Finds the `for` loop inside `expr`, which may itself be wrapped by one or more
macrocalls (e.g. `Base.Threads.@threads for ... end` or `Base.@sync Base.@async for ... end`).
Returns the inner `for` expression together with the chain of wrapping
macrocalls (outermost first). Returns `(nothing, nothing)` if no `for` loop
can be found.
"""
function _unwrap_loop(expr)
    wrappers = Any[]
    while expr isa Expr
        if expr.head == :for
            return expr, wrappers
        elseif expr.head == :macrocall
            target = nothing
            for a in expr.args[2:end]
                if _contains_for(a)
                    target = a
                    break
                end
            end
            target === nothing && return nothing, nothing
            push!(wrappers, expr)
            expr = target
        else
            return nothing, nothing
        end
    end
    return nothing, nothing
end

"""
    _rewrap_loop(for_expr, wrappers)

Rebuilds a macro-wrapped `for` loop from its (possibly empty) chain of
wrapping macrocalls, substituting `for_expr` for the original loop.
"""
function _rewrap_loop(for_expr, wrappers)
    result = for_expr
    for w in reverse(wrappers)
        args = map(w.args) do a
            a isa Expr && _contains_for(a) ? result : a
        end
        result = Expr(:macrocall, args...)
    end
    return result
end

"""
    _build_loop_expr(var, iter_sym, new_body, job_sym, wrappers)

Constructs the iteration loop that updates `job_sym` after every iteration of the
transformed body, so the progress start and completion are still reported
correctly. The loop may be re-wrapped by the caller's macros (e.g.
`Threads.@threads`, `Base.@sync`), which is how multithreading is expressed.
"""
function _build_loop_expr(var, iter_sym, new_body, job_sym, wrappers)
    loop = :(
        for $var in $iter_sym
            $new_body
            Progbiotic.next!($job_sym)
        end
    )
    return _rewrap_loop(loop, wrappers)
end

"""
    _build_level_block(parent, job_sym, opts, body_expr;
                       is_loop, iter_sym=nothing, iter=nothing,
                       milestone_count=0, thread_ctx=nothing)

Registers a job for one `@progress` level (a `for` loop or a `begin ... end`
block), runs `body_expr` under it with a `ProgbioticLogger` installed so log
records emitted inside the level are captured into its job, and on exit completes
any pending statement subtasks and the job itself. When `thread_ctx` is a symbol,
it is scoped-rebound to the new job for the duration of the block and restored
afterwards, so contexts automatically track the innermost job.

A loop job's total is inferred from its iterable; a block job's total is
`max(1, milestone_count)` — the number of `@progress "desc"` milestones it
contains — and, when positive, the job is marked as a milestone container whose
state tracks how many milestones have completed.
"""
function _build_level_block(parent, job_sym, opts, body_expr;
                            is_loop::Bool = false,
                            iter_sym::Union{Symbol, Nothing} = nothing,
                            iter = nothing,
                            milestone_count::Int = 0,
                            thread_ctx::Union{Symbol, Nothing} = nothing)
    total = is_loop ? :(Progbiotic.infer_total($iter_sym)) : max(1, milestone_count)
    kind  = is_loop || milestone_count == 0 ? :bar : :container

    node_kws = Any[Expr(:kw, :desc, opts[:desc]),
                   Expr(:kw, :theme, opts[:theme]),
                   Expr(:kw, :kind, QuoteNode(kind)),
                   _vanish_kws(opts)...,
                   _extract_extra_kws(opts)...]

    saved_ctx = gensym("saved_ctx")
    bind = opts[:bind] === nothing ? :() : :($(opts[:bind]) = $job_sym)
    rebind_ctx = thread_ctx === nothing ? :() : :($thread_ctx = $job_sym)
    restore_ctx = thread_ctx === nothing ? :() : :($thread_ctx = $saved_ctx)
    # a log_file given at this level attaches (or re-attaches) the tree's sink: a sink
    # belongs to the whole scope, so it is the root's however deep the level that asked
    sink_call = opts[:log_file] === nothing ? :() :
        :(Progbiotic._ensure_log_sink!($job_sym, $(opts[:log_file])))

    bindings = Any[:($saved_ctx = $(thread_ctx === nothing ? nothing : thread_ctx))]

    completion = :(if Progbiotic.pbtotal($job_sym) !== nothing &&
                      Progbiotic.pbdone($job_sym) < Progbiotic.pbtotal($job_sym)
                       Progbiotic.update!($job_sym, Progbiotic.pbtotal($job_sym))
                   end)

    # the level's body runs with a logger that captures log records into this level's
    # node. Nested levels install their own logger, which shadows this one, so log calls
    # always resolve to the innermost active node.
    capture = opts[:capture_logs] === nothing ? true : opts[:capture_logs]
    body = quote
        let $(bindings...)
            $sink_call
            $bind
            $rebind_ctx
            try
                Progbiotic._with_log_capture($job_sym, $capture) do
                    $body_expr
                end
            finally
                $restore_ctx
                Progbiotic._complete_statement_jobs!($job_sym)
                $completion
            end
        end
    end

    block = if parent !== nothing
        quote
            $job_sym = Progbiotic.child($parent, $total; $(node_kws...))
            $body
        end
    else
        # the outermost level *is* the tree, so building its node starts the render task
        # and running the body under it hands the terminal back when the scope ends
        root = :(Progbiotic._root_bar($total, $(opts[:title]), $(opts[:final_depth]),
                                      $(opts[:log_file]), $(opts[:io]); $(node_kws...)))
        quote
            Progbiotic._with_root($root) do $job_sym
                $body
            end
        end
    end

    # the loop's iterable is named once, outside everything that reads it: the node's
    # total is inferred from it before the node exists
    return is_loop ? :(let $iter_sym = $iter
                           $block
                       end) : block
end

# counts the direct `@progress "desc"` statement invocations in a begin/end block
# body. These are the block's "milestones": they give the block job its total and
# each one completed advances the block's progress by one.
function _count_milestones(body_expr)
    body_expr isa Expr && body_expr.head == :block || return 0
    n = 0
    for arg in body_expr.args
        arg isa LineNumberNode && continue
        if _is_macrocall_progress(arg)
            m_args = _extract_macrocall_args(arg)
            if !isempty(m_args)
                last = m_args[end]
                # statement-form only: no loop (possibly macro-wrapped) and no block body.
                if !(last isa Expr && (last.head == :block || _contains_for(last)))
                    n += 1
                end
            end
        end
    end
    return n
end

"""
    _build_progress_level(m_args, parent, parent_opts, thread_ctx) -> (block, opts)

Parses one `@progress` invocation's arguments and builds the code for its level:
form detection (loop / block / statement), option parsing, vanish inheritance from
the enclosing level, `with=<ctx>` threading, and the context save/rebind/restore
wrapping. Returns the generated block together with the parsed options (so the
caller can inspect e.g. `opts[:with]` or `opts[:title]`).
"""
function _build_progress_level(m_args, parent,
                               parent_opts::Union{Dict{Symbol, Any}, Nothing},
                               thread_ctx::Union{Symbol, Nothing})
    body_expr = m_args[end]
    cfg_args  = m_args[1:end-1]

    for_expr, wrappers = _unwrap_loop(body_expr)
    is_block = body_expr isa Expr && body_expr.head == :block
    is_loop = for_expr !== nothing &&
        (@capture(for_expr, for var_ = iter_ body_ end) || @capture(for_expr, for var_ in iter_ body_ end))
    # a bare `@progress "desc"` statement has no loop/block body: all args are config.
    opts = _parse_progress_args(is_loop || is_block ? cfg_args : m_args)

    # inherit vanishing behaviour from the enclosing @progress level.
    if parent_opts !== nothing
        if opts[:vanish] === nothing && parent_opts[:vanish] !== nothing
            opts[:vanish] = parent_opts[:vanish]
        end
        if opts[:vanish_timeout] === nothing && parent_opts[:vanish_timeout] !== nothing
            opts[:vanish_timeout] = parent_opts[:vanish_timeout]
        end
        if opts[:capture_logs] === nothing && parent_opts[:capture_logs] !== nothing
            opts[:capture_logs] = parent_opts[:capture_logs]
        end
        # A sink configured on an outer level keeps collecting on every inner one.
        if opts[:log_file] === nothing && parent_opts[:log_file] !== nothing
            opts[:log_file] = parent_opts[:log_file]
        end
    end

    # `with=<ctx>` threads an existing bar: register under it, and carry it (if a symbol)
    # down to nested levels.
    if opts[:with] !== nothing
        ctxv = gensym("with_ctx")
        level_parent = ctxv
        # the `with=` context is an existing value: rebind it around this level.
        carried      = opts[:with] isa Symbol ? opts[:with] : thread_ctx
        block_thread = carried
    else
        ctxv = nothing
        level_parent = parent
        # the inherited context tracks this level (restored afterwards); a level's
        # own `bind` is a fresh assignment instead.
        carried      = opts[:bind] isa Symbol ? opts[:bind] : thread_ctx
        block_thread = thread_ctx
    end

    block = if is_loop
        job_sym   = gensym("child_job")
        iter_sym  = gensym("child_iter")
        new_body  = _transform_progress_ast(body, job_sym, opts, carried)
        loop_expr = _build_loop_expr(var, iter_sym, new_body, job_sym, wrappers)
        _build_level_block(level_parent, job_sym, opts, loop_expr;
                           is_loop = true, iter_sym = iter_sym, iter = iter,
                           thread_ctx = block_thread)
    elseif is_block
        # `@progress "desc" begin ... end`: register a block node and run the
        # (transformed) block body under it.
        job_sym  = gensym("child_job")
        new_body = _transform_progress_ast(body_expr, job_sym, opts, carried)
        _build_level_block(level_parent, job_sym, opts, new_body;
                           milestone_count = _count_milestones(body_expr),
                           thread_ctx = block_thread)
    else
        # `@progress "desc"` statement: register a named subtask (milestone) under
        # the enclosing node.
        job_sym = gensym("stmt_job")
        _build_statement_block(level_parent, job_sym, opts)
    end

    if opts[:with] !== nothing
        # evaluate the context once, check it, and run the level's code against it.
        guard = :($ctxv isa Progbiotic.Progress ||
                  throw(Progbiotic.ProgbioticError(
                      "@progress: `with=` expects a bar, e.g. one bound by the caller's ", 
                      "@progress; got ", repr($ctxv))))
        block = quote
            let $ctxv = $(opts[:with])
                $guard
                $block
            end
        end
    end
    return block, opts
end

"""
    _build_statement_block(parent, job_sym, opts)

Builds the code for a `@progress "desc"` statement with no loop or block body: it
registers a named subtask (milestone) under `parent` and optionally binds it. A milestone
has no total of its own, and is kept on screen by `final_depth` or vanishes like any other
finished bar otherwise.
"""
function _build_statement_block(parent, job_sym, opts)
    node_kws = Any[Expr(:kw, :desc, opts[:desc]),
                   Expr(:kw, :theme, opts[:theme]),
                   Expr(:kw, :kind, QuoteNode(:milestone)),
                   _vanish_kws(opts)...,
                   _extract_extra_kws(opts)...]

    bind = opts[:bind] === nothing ? :() : :($(opts[:bind]) = $job_sym)
    sink_call = opts[:log_file] === nothing ? :() :
        :(Progbiotic._ensure_log_sink!($job_sym, $(opts[:log_file])))

    if parent !== nothing
        return quote
            $job_sym = Progbiotic.child($parent, nothing; $(node_kws...))
            $sink_call
            $bind
        end
    end

    # a bare `@progress "desc"` with no enclosing scope is a tree of one milestone
    root = :(Progbiotic._root_bar(nothing, $(opts[:title]), $(opts[:final_depth]),
                                  $(opts[:log_file]), $(opts[:io]); $(node_kws...)))
    return quote
        Progbiotic._with_root($root) do $job_sym
            $sink_call
            $bind
        end
    end
end

"""
Recursively transforms the AST, linking nested `@progress` invocations to parent jobs
and carrying the context variable (`thread_ctx`) so contexts automatically track
the innermost job.
"""
function _transform_progress_ast(expr, parent, parent_opts::Dict{Symbol, Any},
                                 thread_ctx::Union{Symbol, Nothing} = nothing)
    if _is_macrocall_progress(expr)
        m_args = _extract_macrocall_args(expr)
        isempty(m_args) && return expr
        block, _ = _build_progress_level(m_args, parent, parent_opts, thread_ctx)
        return block
    elseif expr isa Expr
        return Expr(expr.head, map(arg -> _transform_progress_ast(arg, parent, parent_opts, thread_ctx), expr.args)...)
    else
        return expr
    end
end

"""
    @progress [options] for var in collection ... end
    @progress [options] begin ... end

Implicitly builds a progress tree across nested loops and blocks. The `for` loop may be
wrapped by other macros that affect it, e.g. `Base.Threads.@threads`:

    @progress "Downloading weights" Base.Threads.@threads for i in 1:100
        ...
    end

A plain `begin ... end` block is also accepted: the block itself becomes a job in
the tree (starting at 0% and completing when the block finishes), so you can group
phases or produce a context without a loop:

    @progress "foo" begin
        @progress "bar" for j in 1:10
            ...
        end
    end

A bare description — `@progress "desc" [options]` with no loop or block body —
registers a named subtask under the enclosing progress scope, for marking
sequential steps:

    @progress "foo" d=1 begin
        @progress "job 1"
        sleep(0.5)
        @progress "job 2"
        sleep(0.5)
        @progress "job 3"
        sleep(0.5)
    end

These subtasks are *milestones*: they have no total of their own, so they show no
rate and no ETA — instead they report their elapsed time — and each one finishes
when the next subtask is registered (or when the enclosing scope finishes). The
enclosing `begin ... end` block's total is the number of milestones it contains,
and its progress advances as each milestone completes (here `foo` runs 0/3 → 3/3).
Finished milestones are kept on screen by `final_depth` (e.g. `d=1` above).

# contexts and subroutines

A context can be bound with `(ctx => "desc")` or a bare symbol as the first
argument (`@progress ctx "desc"`). A context *is* a bar -- the node the macro made --
and it automatically tracks the innermost running node inside nested `@progress`
levels, restored afterwards, so it can be passed to subroutines:

    function subtask(ctx, n)
        @progress with=ctx "working..." for k in 1:n
            ...
        end
    end

    @progress ctx "outer..." for i in 1:10
        @progress "inner" for j in 1:10
            subtask(ctx, i)          # ctx already points at "inner" here
        end
    end

`with=ctx` registers the new bar under the one `ctx` points at, in the same tree
(no new gutter). The context is also scoped-rebound to the new node inside its body,
so deeper calls thread further, and restored afterwards.

# syntax
- `@progress "Description" for ...`
- `@progress ("Description", THEME) for ...`
- `@progress (bar => THEME) for ...`  (binds `bar` to the node the macro made)
- `@progress (bar => ("Description", THEME)) for ...`
- `@progress ("Description", THEME, vanish_timeout=1.0) for ...`
- `@progress "Description"`  (a named subtask; no body)
- `@progress ctx "Description" for ...`  (binds `ctx`; shorthand for `(ctx => ...)`)
- `@progress "Description" with=ctx for ...`  (register under `ctx`, e.g. in a subroutine)

# short form options

The keyword options accept short aliases:
- `d=1`      — `final_depth=1` (levels of children kept in the final render)
- `v=false`  — `vanish=false` (keep bars on screen)
- `v=1.2`    — `vanish_timeout=1.2` (seconds)
- `t=OCEAN`  — `theme=OCEAN`

To run a loop multithreaded, wrap it with `Threads.@threads` instead of passing an
option:

    @progress "Downloading weights" Base.Threads.@threads for i in 1:100
        ...
    end

# per-bar styling

A level can override its theme's glyphs or bar width without defining a whole
theme (`spinner`/`barunits`/`caps`/`head` may be strings or `Char` vectors):

    @progress "x" spinner="⠋⠙⠹" barunits="░▒▓█" empty="░" caps="[]" head=">" width=30 for i in 1:10
        ...
    end

`caps` flanks the bar (e.g. `[████░░]`); `head` marks the tip of an in-progress
bar (e.g. `█████>░░░`). To build a custom theme by mixing elements of the built-in
ones, use the `Theme` copy constructor: `Theme(AMBER; spinner=EMERALD.spinner)`.

# vanishing

By default, completed bars vanish from the tree shortly after finishing
(`vanish_timeout` defaults to 0.5s), so a long-running loop does not fill the
screen with stale, finished sub-bars. Pass `vanish=false` to keep every bar on
screen, or `vanish_timeout=<seconds>` to control how long finished bars linger.
These options are inherited by nested `@progress` levels unless overridden.

# log capture

`@info`, `@debug`, `@warn` and `@error` calls inside a `@progress` scope are
intercepted and drawn underneath the bar of the innermost active node, then pruned
once that node's `vanish` timeout elapses:

    @progress "Ingesting" total=100 vanish=2.0 for i in 1:100
        i % 25 == 0 && @info "checkpoint at record \$i"
    end

`capture=` (alias `capture_logs=`) selects the levels that are drawn: `true`
(default, every level), `false` (nothing — every record goes to the surrounding
logger), a `LogLevel`, or a collection such as `[:warn, :error]`. Levels that
are not captured are forwarded to the logger that was current when the scope was
entered. Nested scopes capture independently, so inner logs belong to the inner
bar and inherit its `vanish` timeout.

# Postfix metrics

set_postfix! attaches live key/value metrics to the innermost active bar. They are
rendered inline on the right-hand side of the line and overwritten on every call,
so they are state rather than history and never clutter the scrollback:

    @progress "Training" total=100 for epoch in 1:100
        set_postfix!(loss = round(loss, digits = 4), lr = 1e-4)
    end

# permanent logs

Every intercepted record can also be appended, permanently and in plain text, to a
file or a stream, so a line that has vanished from the screen still survives in the
build log:

    @progress "Ingesting" total=100 vanish=2.0 log_file="ingest.log" for i in 1:100
        i % 25 == 0 && @info "checkpoint at record \$i"
    end

log_file accepts a path (opened in append mode, and closed when the scope ends) or
any IO you own. Nested levels inherit the sink of the level that set it.

# output stream

A scope draws to stdout by default. Pass io= to send it elsewhere, which is mainly
useful in tests and in library code that manages its own streams:

    @progress "Silent" total=10 io=IOBuffer() for i in 1:10
        ...
    end

When the stream is not an interactive terminal - a pipe, a redirected file, or a CI
build - the scope emits flat, ANSI-free lines instead of drawing a gutter, and
progress is reported at most once per flat_step percent.

# final depth

Once the tree completes, the live gutter collapses finished jobs to just the
top-level summary. Pass `final_depth=N` to keep `N` levels of children in the
final render (0 keeps only the top-level job, 1 also keeps its direct children,
and so on):

    @progress "foo" final_depth=1 for i in 1:10
        ...
    end
"""
macro progress(args...)
    isempty(args) && error("@progress requires a loop, a block, or a description")

    block, _ = _build_progress_level(args, nothing, nothing, nothing)
    return esc(block)
end

"""
    _root_bar(total, title, final_depth, log_file, io; kwargs...) -> Progress

Build the node that roots a @progress tree. `io` and `log_file` are optional, so they are
only forwarded when actually given; this keeps the generated code free of conditionals and
lets the macro stay a pure AST transformation.

The root's own vanish defaults to nothing, which keeps the tree on screen for the whole
scope, while `child_vanish = 0.5` is what its children get when they ask for none of their
own.
"""
function _root_bar(total, title, final_depth, log_file, io;
                   desc::AbstractString = "", theme::Theme = AMBER, kind::Symbol = :bar,
                   vanish = nothing, vanish_timeout = nothing, width::Integer = 0,
                   spinner = nothing, barunits = nothing, empty = nothing,
                   caps = nothing, head = nothing)
    return Progress(total; desc = desc, kind = kind, title = title,
                    final_depth = final_depth, child_vanish = 0.5, width = width,
                    theme = _apply_style(theme, spinner, barunits, empty, caps, head),
                    vanish = vanish, vanish_timeout = vanish_timeout,
                    log_file = log_file, io = io === nothing ? stdout : io)
end

"""
    _with_root(f, bar::Progress)

Start the render task for a freshly built root, run f(bar) with it, and hand the terminal
back when f returns or throws. A @progress scope is exactly this call.
"""
function _with_root(f::Function, bar::Progress)
    start_render!(bar)
    try
        return f(bar)
    finally
        stop_render!(bar)
    end
end
