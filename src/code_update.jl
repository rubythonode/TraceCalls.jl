# if !isdefined(Main, :Revise) && !haskey(ENV, "JULIA_REVISE")
#     # This doesn't work. Either the ENV from this module is different from the
#     # Revise ENV, or the import happens before ENV can be set.
#     ENV["JULIA_REVISE"] = "manual"   # FIXME; that's still not great
# end
import Revise
using Revise: ModDict, parse_source, RelocatableExpr
import ClobberingReload
using ClobberingReload: scrub_redefinition_warnings

export apply_code!, revert_code!, update_code_revertible, RevertibleCodeUpdate,
    CodeUpdate, EvalableCode, source

################################################################################

function only(collection)
    @assert length(collection)==1 "only: `collection` was expected to contain one element; contains $(length(collection))"
    return first(collection)
end
only(collection::Base.Generator) = only(collect(collection)) # could be better...


function counter(seq)  # could use DataStructures.counter, but it's a big dependency
    di = Dict()
    for x in seq; di[x] = get(di, x, 0) + 1 end
    di
end

################################################################################

struct CodeUpdate
    md::ModDict
end
CodeUpdate() = CodeUpdate(ModDict())

""" `CodeUpdate(::Vector{EvalableCode})` is merely a collection of `EvalableCode`.
Support `apply_code!(::CodeUpdate)`, and can be `merge`d together. """
function Base.merge(cu1::CodeUpdate, cus::CodeUpdate...)
    md = ModDict()
    for cu in [cu1, cus...]
        for (mod::Module, set) in cu.md
            md[mod] = union(get(md, mod, OrderedSet{RelocatableExpr}()), set)
        end
    end
    return CodeUpdate(md)
end
# Base.getindex(cu::CodeUpdate, ind::UnitRange) = CodeUpdate(cu.ecs[ind])
Base.getindex(cu::CodeUpdate, ind::Module) = cu.md[ind]
Base.length(cu::CodeUpdate) = length(cu.md)
apply_code!(cu::CodeUpdate) = scrub_redefinition_warnings() do
    Revise.eval_revised(cu.md)
end
function MakeRelocatableExpr(ex::Expr)
    # because the Revise constructor (via the convert method) is unsafe (!)
    rex = RelocatableExpr(ex.head, ex.args)
    rex.typ = ex.typ
    rex
end
        
to_expr(rex::RelocatableExpr) =
    # Necessary because sometimes rex.typ is #undef, and Revise.convert(::RelocatableExpr)
    # uses rex.typ. No idea why/when that's happening. Don't think it's on my end.
    Expr(rex.head, rex.args...)

empty_rex = MakeRelocatableExpr(:(identity(nothing))) # a dummy
function apply(fn::Function, rex::RelocatableExpr, mod::Module)
    r = fn(convert(Expr, rex), mod)
    r === nothing ? empty_rex : MakeRelocatableExpr(r)
end

is_empty_rex(rex::RelocatableExpr) = rex === empty_rex
Base.map(fn::Function, cu::CodeUpdate) =
    CodeUpdate(ModDict(mod=>filter(rex->!is_empty_rex(rex),
                                   OrderedSet{RelocatableExpr}(apply(fn, rex, mod)
                                                               for rex in set_rex))
                       for (mod, set_rex) in cu.md))
Base.filter(fn::Function, cu::CodeUpdate) =
    map((expr, mod)->fn(expr, mod) ? expr : nothing, cu) #a lazy & wasteful implementation

""" `RevertibleCodeUpdate(apply::CodeUpdate, revert::CodeUpdate)` contains code
to modify a module, and revert it back to its former state. Use `apply_code!` and
`revert_code!`, or `(::RevertibleCodeUpdate)() do ... end` to temporarily apply the code.
"""
struct RevertibleCodeUpdate
    apply::CodeUpdate
    revert::CodeUpdate
end
function RevertibleCodeUpdate(fn::Function, current::CodeUpdate)
    # Formerly defined as simply
    #    RevertibleCodeUpdate(map((expr, mod)->fn(expr), revert), revert)
    # but we want to get rid of the unmodified code in `set_revert`, so it got imperative.
    md_apply = ModDict()
    md_revert = ModDict()
    for (mod, set_rex) in current.md
        set_apply = OrderedSet{RelocatableExpr}()
        set_revert = OrderedSet{RelocatableExpr}()
        for rex in set_rex
            apply_res = fn(convert(Expr, rex))
            if apply_res !== nothing
                push!(set_apply, MakeRelocatableExpr(apply_res))
                push!(set_revert, rex)
            end
        end
        if !isempty(set_apply)
            md_apply[mod] = set_apply
            md_revert[mod] = set_revert
        end
    end
    return RevertibleCodeUpdate(CodeUpdate(md_apply), CodeUpdate(md_revert))
end
    
EmptyRevertibleCodeUpdate() = RevertibleCodeUpdate(CodeUpdate(), CodeUpdate())
Base.merge(rcu1::RevertibleCodeUpdate, rcus::RevertibleCodeUpdate...) =
    RevertibleCodeUpdate(merge((rcu.apply for rcu in (rcu1, rcus...))...),
                         merge((rcu.revert for rcu in (rcu1, rcus...))...))
apply_code!(rcu::RevertibleCodeUpdate) = apply_code!(rcu.apply)
revert_code!(rcu::RevertibleCodeUpdate) = apply_code!(rcu.revert)
function (rcu::RevertibleCodeUpdate)(body_fn::Function)
    try
        # It's safer to have the `apply_code!` inside the try, because we should be
        # able to assume that running `revert_code!` is harmless even if apply_code!
        # had an error half-way through.
        apply_code!(rcu)
        @eval $body_fn()   # necessary to @eval because of world age
    finally
        revert_code!(rcu)
    end
end


################################################################################
# These should go into MacroTools/ExprTools

function is_function_definition(expr::Expr)
    l = longdef1(expr)
    l.head == :function && length(l.args) > 1 # `function foo end` is not a definition
end
is_function_definition(::Any) = false

is_call_definition(fundef_di::Dict) = @capture(fundef_di[:name], (a_::b_) | (::b_))
is_call_definition(fundef) = is_call_definition(splitdef(fundef))
""" `is_fancy_constructor_definition(fundef)` is true for constructors that have both
parameters and where-parameters (eg. `Vector{T}(x) where T = ...`) """
is_fancy_constructor_definition(fundef_di::Dict) =
    !isempty(get(fundef_di, :params, ())) && !isempty(get(fundef_di, :whereparams, ()))
is_fancy_constructor_definition(fundef)=is_fancy_constructor_definition(splitdef(fundef))

strip_docstring(x) = x
function strip_docstring(x::Expr)
    if x.head == :macrocall && x.args[1] == GlobalRef(Core, Symbol("@doc"))
        strip_docstring(x.args[3])
    else
        x
    end
end

################################################################################

function revertible_update_helper(fn)
    function (code)
        res = fn(code)
        if res === nothing
            (nothing, nothing)
        else
            (res, code)
        end
    end
end

# Return the list of files in `mod`
# Memoizing is technically wrong, since the user could conceivably add a file.
# This seems OK until Revise.jl provides module_files
@memoize ObjectIdDict module_files(mod::Module) =
    # copy because Revise.jl aggressively reuses objects
    copy(Revise.parse_pkg_files(Symbol(mod)))

code_of(mod::Module) = 
    merge((code_of(mod, file) for file in module_files(mod))...)
           
code_of(mod::Module, file::String) =
    (haskey(Revise.file2modules, file) ? CodeUpdate(Revise.file2modules[file].md) :
     CodeUpdate())
function code_of(included_file::String)::CodeUpdate
    parse_source(included_file, Main, pwd())
    code_of(Main, included_file)
end

method_file_counts(fn_to_change) =
    counter((mod, isa(file, AbstractString) ? realpath(abspath(file)): file)
            # The Set is so that we count methods that have the same file and line number.
            # (i.e. optional files, although it might catch macroexpansions too; not
            # sure if that's good or not)
            for (mod, file, line) in Set((m.module, functionloc(m)...)
                                         for m in methods(fn_to_change).ms))

struct UpdateInteractiveFailure
    fn::Union{Function, Type}
end
Base.show(io::IO, upd::UpdateInteractiveFailure) =
    write(io, "Cannot find source of some method of $(upd.fn). Perhaps it was defined interactively? Try adding `@traceable` in front of its definition.")

struct MissingMethodFailure
    count::Int
    correct_count::Int
    fn::Union{Function, Type}
    file::String
end
Base.show(io::IO, fail::MissingMethodFailure) =
    write(io, "Only $(fail.count)/$(fail.correct_count) methods of $(fail.fn) in $(fail.file) were found.")

""" `parse_mod!` fills up Revise.file2modules for that module, and returns `nothing` """
function parse_mod!(mod::Module)
    if module_parent(mod) !== Main
        parse_mod!(module_parent(mod))
    elseif mod == Base
        if !haskey(Revise.file2modules, Revise.sysimg_path)
            parse_source(Revise.sysimg_path, Main, dirname(Revise.sysimg_path))
        end
    elseif !haskey(Revise.file2modules, ClobberingReload.module_definition_file(mod))
        Revise.parse_pkg_files(Symbol(mod)) # it's a side-effect of this function...
        @assert haskey(Revise.file2modules, ClobberingReload.module_definition_file(mod))
    end
    nothing
end


""" `get_function(mod::Module, fundef::Expr)::Function` returns the `Function` which this
`fundef` is defining. This code works only when the Function already exists. """
get_function_(mod::Module, fundef::Expr)::Union{Function, Type} =
    eval(mod, splitdef(fundef)[:name])

""" `get_function(mod, def)` returns the ::Function corresponding to `def` if there is
one (and it's not a callable-object definition), otherwise returns `nothing` """
function get_function(mod::Module, def)
    expr = strip_docstring(def)
    if is_function_definition(expr) &&
        !is_call_definition(expr)
        return get_function_(mod, expr)
    else
        return nothing
    end
end

function code_of(fn::Union{Function, Type}; when_missing=warn)::CodeUpdate
    if when_missing in (false, nothing); when_missing = _->nothing end
    function process(mod, file, correct_count)
        if mod == Main || file === nothing
            when_missing(UpdateInteractiveFailure(fn))
            return CodeUpdate()
        end
        if !haskey(Revise.file2modules, file)
            parse_mod!(mod)
            if !haskey(Revise.file2modules, file)
                # Should fail somehow?
                return CodeUpdate()
            end
        end
        count = 0  # how many methods were found
        rcu = filter((expr, expr_mod) -> (get_function(expr_mod, expr) == fn ?
                                          (count += 1; true) : false),
                     code_of(mod, file)::CodeUpdate)
        if count != correct_count
            when_missing(MissingMethodFailure(count, correct_count, fn, file))
        end
        rcu
    end
    return merge((process(mod, file, correct_count)
                  for ((mod, file), correct_count) in method_file_counts(fn))...)
end



"""
    update_code_revertible(new_code_fn::Function, obj::Union{Module, Function, String})

applies the source code transformation function `new_code_fn` to each expression in the
source code of `obj`, and returns a `RevertibleCodeUpdate` which can put into
effect/revert that new code. `obj` can be a module, a function (will transform each
method), or a Main-included ".jl" filename.

`update_code_revertible` itself is side-effect free (it neither modifies the source file,
nor the state of `Julia`). See the README for usage info.

IMPORTANT: if some expression `x` should not be modified, return `nothing` instead of `x`.
This will significantly improve performance. """
function update_code_revertible(fn::Function, mod::Module)
    if mod == Base; error("Cannot update all of Base (only specific functions/files)") end
    return RevertibleCodeUpdate(fn, code_of(mod))
end

update_code_revertible(new_code_fn::Function, file::String) =
    RevertibleCodeUpdate(new_code_fn, code_of(file))
update_code_revertible(new_code_fn::Function, fn_to_change::Union{Function, Type};
                       when_missing=warn) =
    RevertibleCodeUpdate(new_code_fn, code_of(fn_to_change; when_missing=when_missing))


""" `source(fn::Function, when_missing=warn)::Vector` returns a vector of the parsed
code corresponding to each method of `fn`. It can fail for any number of reasons,
and `when_missing` is a function that will be passed an exception when it cannot find
the code.
"""
function source(obj::Union{Module, Function}; kwargs...)
    res = []
    # Loop because flattening comprehensions are broken in 0.6
    for (mod2, rex_set) in code_of(obj).md
        for rex in rex_set
            push!(res, to_expr(rex))
        end
    end
    res
end
