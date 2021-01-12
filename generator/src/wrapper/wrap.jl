struct VulkanWrapper
    handles::Vector{Expr}
    structs::Vector{Expr}
    funcs::Vector{Expr}
    misc::Vector{Expr}
end

Base.show(io::IO, vw::VulkanWrapper) = print(io, "VulkanWrapper with $(length(vw.handles)) handles, $(length(vw.structs)) structs, $(length(vw.funcs)) functions and $(length(vw.misc)) others.")

function wrap(spec::SpecHandle)
    :(mutable struct $(remove_vk_prefix(spec.name)) <: Handle
         handle::$(spec.name)
     end)
end

function wrap(spec::SpecStruct)
    p = Dict(
        :category => :struct,
        :decl => :($(remove_vk_prefix(spec.name)) <: $(spec.is_returnedonly ? :ReturnedOnly : :(VulkanStruct{$(needs_deps(spec))})))
    )
    if spec.is_returnedonly
        p[:fields] = map(x -> :($(nc_convert(SnakeCaseLower, x.name))::$(nice_julian_type(x))), spec.members)
    else
        p[:fields] = [
            :(vks::$(spec.name)),
        ]
        needs_deps(spec) && push!(p[:fields], :(deps::Vector{Any}))
    end

    reconstruct(p)
end

function from_vk_call(x::Spec)
    prop = :(x.$(x.name))
    jtype = nice_julian_type(x)
    @match t = x.type begin
        :Cstring => :(unsafe_string($prop))

        # array pointer (do not unsafe_wrap a Ptr{Cvoid} type because we can't know the type to wrap to)
        :(Ptr{$pt}) && if !isnothing(x.len) && pt ≠ :Cvoid end => @match jtype begin
            :(Vector{$_}) => :(unsafe_wrap($jtype, $prop, x.$(x.len); own=true))
        end

        if is_count_variable(x) end => nothing
        if x.type ∈ spec_handles.name end => :($(remove_vk_prefix(x.type))($prop))
        GuardBy(is_ntuple) && if ntuple_type(x.type) ∈ filter(x -> x.is_returnedonly, spec_structs).name end => :(from_vk.($(remove_vk_prefix(ntuple_type(x.type))), $prop))
        if follow_constant(t) == jtype end => prop
        _ => :(from_vk($jtype, $prop))
    end
end

function vk_call(x::Spec)
    var = var_from_vk(x.name)
    jtype = nice_julian_type(x)
    @match x begin
        ::SpecStructMember && if x.type == :VkStructureType && parent(x) ∈ keys(stypes) end => stypes[parent(x)]
        ::SpecStructMember && if is_semantic_ptr(x.type) end => :(unsafe_convert($(x.type), $var))
        GuardBy(is_count_variable) => :(pointer_length($(var_from_vk(first(x.arglen))))) # Julia works with arrays, not pointers, so the length information can directly be retrieved from them
        GuardBy(is_pointer_start) => 0 # always set first* variables to 0, and the user should provide a (sub)array of the desired length
        if x.type ∈ spec_handles.name end => var # handled by unsafe_convert in ccall

        # constant pointer to a unique object
        if is_ptr(x.type) && isnothing(x.len) && (x.is_constant || (func = func_by_name(x.func); func.type == QUERY && x ≠ last(children(func)))) end => @match x begin
            if ptr_type(x.type) ∈ spec_structs.name end => var # handled by cconvert and unsafe_convert in ccall
            if x.requirement == OPTIONAL end => :($var == $(default(x)) ? $(default(x)) : Ref($var)) # allow optional pointers to be passed as C_NULL instead of a pointer to a 0-valued integer
            _ => :(Ref($var))
        end
        _ => @match jtype begin
            :String || :Bool || :(Vector{$et}) || if jtype == follow_constant(x.type) end => var # conversions are already defined
            if jtype == remove_vk_prefix(x.type) && x.type ∈ spec_structs.name end => :($var.vks)
            _ => :(to_vk($(x.type), $var)) # fall back to the to_vk function for conversion
        end
    end
end

wrap_return(ex, type, jtype) = @match t = type begin
    :VkResult => :(@check($ex))
    :Cstring => :(unsafe_string($ex))
    GuardBy(in(spec_handles.name)) => :($(remove_vk_prefix(t))($ex)) # call handle constructor
    GuardBy(in(vcat(spec_enums.name, spec_bitmasks.name))) => ex # don't change enumeration variables since they won't be wrapped under a new name
    if is_fn_ptr(type) || follow_constant(type) == jtype end => ex # Vulkan and Julian types are the same (up to aliases)
    _ => :(from_vk($jtype, $ex)) # fall back to the from_vk function for conversion
end

wrap_implicit_return(params::AbstractVector{SpecFuncParam}) = length(params) == 1 ? wrap_implicit_return(first(params)) : Expr(:tuple, wrap_implicit_return.(params)...)

function is_query_param(param::SpecFuncParam)
    params = func_by_name(param.func).params
    query_param_index = findlast(x -> !x.is_constant && is_ptr(x.type), params)
    query_param_index == findfirst(==(param), params)
end

broadcast_ex(ex) = Expr(:., ex.args[1], Expr(:tuple, ex.args[2:end]...))

"""
Build a return expression from an implicit return parameter.
Implicit return parameters are pointers that are mutated by the API, rather than returned directly.
API functions with implicit return parameters return either nothing or a return code, which is
automatically checked and not returned by the wrapper.
Such implicit return parameters are `Ref`s or `Vector`s holding either a base type or an API struct Vk*.
They need to be converted by the wrapper to their wrapping type.
"""
function wrap_implicit_return(return_param::SpecFuncParam)
    p = return_param
    @assert is_ptr(p.type) "Invalid implicit return parameter API type. Expected $(p.type) <: Ptr"
    @match pt = ptr_type(p.type) begin

        # array pointer
        if !isnothing(p.len) end => @match ex = wrap_return(p.name, pt, innermost_type((nice_julian_type(p)))) begin
            ::Symbol => ex
            ::Expr => broadcast_ex(ex) # broadcast result
        end

        # pointer to a unique object
        _ => wrap_return(:($(p.name)[]), pt, innermost_type((nice_julian_type(p)))) # call return_expr on the dereferenced pointer
    end
end

wrap_api_call(spec::SpecFunc, args) = wrap_return(:($(spec.name)($(args...))), spec.return_type, nice_julian_type(spec.return_type))

init_wrapper_func(spec::SpecFunc) = Dict(:category => :function, :name => nc_convert(SnakeCaseLower, remove_vk_prefix(spec.name)), :short => false)
init_wrapper_func(spec::Spec) = Dict(:category => :function, :name => remove_vk_prefix(spec.name), :short => false)

arg_decl(x::Spec) = :($(var_from_vk(x.name))::$(signature_type(nice_julian_type(x))))
kwarg_decl(x::Spec) = Expr(:kw, var_from_vk(x.name), default(x))
drop_arg(x::Spec) = !isempty(x.arglen) || is_pointer_start(x)

function add_func_args!(p::Dict, spec, params)
    params = filter(!drop_arg, params)
    arg_filter = if spec.type ∈ [DESTROY, FREE]
        destroyed_type = destroy_func(spec).handle.name
        x -> !is_optional(x) || x.type == destroyed_type
    else
        !is_optional
    end

    p[:args] = map(arg_decl, filter(arg_filter, params))
    p[:kwargs] = map(kwarg_decl, filter(!arg_filter, params))
end

function wrap(spec::SpecFunc)
    p = init_wrapper_func(spec)

    count_ptr_index = findfirst(x -> x.requirement == POINTER_REQUIRED && x.type == :(Ptr{UInt32}) && contains(lowercase(string(x.name)), "count"), children(spec))
    query_param_index = findlast(x -> !x.is_constant && is_ptr(x.type), children(spec))
    if !isnothing(count_ptr_index)
        count_ptr = children(spec)[count_ptr_index]
        queried_params = getindex(children(spec), findall(x -> x.len == count_ptr.name && !x.is_constant, children(spec)))

        first_call_args = map(@λ(begin
                &count_ptr => count_ptr.name
                GuardBy(in(queried_params)) => :C_NULL
                x => vk_call(x)
        end), children(spec))

        i = 0
        second_call_args = map(@λ(begin
                :C_NULL && Do(i += 1) => queried_params[i].name
                x => x
            end), first_call_args)

        p[:body] = quote
            $(count_ptr.name) = Ref{UInt32}(0)
            $(wrap_api_call(spec, first_call_args))
            $((:($(param.name) = Vector{$(ptr_type(param.type))}(undef, $(count_ptr.name)[])) for param ∈ queried_params)...)
            $(wrap_api_call(spec, second_call_args))
            $(wrap_implicit_return(queried_params))
        end

        args = filter(!in(vcat(queried_params, count_ptr)), children(spec))
    elseif !isnothing(query_param_index)
        query_param = children(spec)[query_param_index]
        call_args = map(@λ(begin
                &query_param => query_param.name
                x => vk_call(x)
            end), children(spec))
        init_query_param = if isnothing(query_param.len)
            :(Ref{$(ptr_type(query_param.type))}())
        else
            if contains(string(query_param.len), "->")
                vars = Symbol.(split(string(query_param.len), "->"))
                len_expr = foldl((x, y) -> :($x.$y), vars[2:end]; init=:($(var_from_vk(first(vars))).vks))
            else
                len_param = spec.params[findfirst(==(query_param.len), spec.params.name)]
                len_expr = vk_call(len_param)
            end
            :(Vector{$(ptr_type(query_param.type))}(undef, $len_expr))
        end

        p[:body] = quote
            $(query_param.name) = $init_query_param
            $(wrap_api_call(spec, call_args))
            $(wrap_implicit_return(query_param))
        end

        if spec.type ∈ [CREATE, ALLOCATE]
            create::SpecCreateFunc = create_func(spec)
            destroy = destroy_func(handle_by_name(ptr_type(query_param.type)))
            if !isnothing(destroy) && isnothing(destroy.destroyed_param.len)
                p_destroy = deconstruct(wrap(destroy.func))
                handle_name = var_from_vk(query_param.name)
                p_destroy[:args][findfirst(==(remove_vk_prefix(ptr_type(query_param.type))), type.(p_destroy[:args]))] = :x
                p_destroy_call = Dict(
                    :name => p_destroy[:name],
                    :args => name.(p_destroy[:args]),
                    :kwargs => name.(p_destroy[:kwargs]),
                )
                p[:body].args[end] = :($handle_name = $(last(p[:body].args)))
                p[:body] = concat_exs(p[:body], (create.batch ? broadcast_ex : identity)(:(finalizer(x -> $(reconstruct_call(p_destroy_call)), $handle_name))))
            end
        end

        args = filter(≠(query_param), children(spec))
    else
        p[:short] = true
        p[:body] = :($(wrap_api_call(spec, map(vk_call, children(spec)))))

        args = children(spec)
    end

    add_func_args!(p, spec, args)

    reconstruct(p)
end

function add_constructor(spec::SpecHandle)
    create = spec_create_funcs[findfirst(x -> !x.batch && x.handle == spec, spec_create_funcs)]
    p_func = deconstruct(wrap(create.func))
    if isnothing(create.create_info_struct)
        # just pass the arguments as-is
        args = p_func[:args]
        kwargs = p_func[:kwargs]
        body = reconstruct_call(Dict(:name => p_func[:name], :args => name.(args), :kwargs => name.(kwargs)))
    else
        p_info = deconstruct(add_constructor(create.create_info_struct))
        args = vcat(p_func[:args], p_info[:args])
        kwargs = vcat(p_func[:kwargs], p_info[:kwargs])

        info_expr = reconstruct_call(Dict(:name => p_info[:name], :args => name.(p_info[:args]), :kwargs => name.(p_info[:kwargs])))
        info_index = findfirst(==(p_info[:name]), type.(p_func[:args]))

        func_call_args = Vector{Any}(name.(p_func[:args]))
        func_call_args[info_index] = info_expr

        deleteat!(args, info_index)

        body = reconstruct_call(Dict(:name => p_func[:name], :args => func_call_args, :kwargs => name.(p_func[:kwargs])))
    end

    reconstruct(Dict(
        :category => :function,
        :name => remove_vk_prefix(spec.name),
        :args => args,
        :kwargs => kwargs,
        :short => true,
        :body => body,
    ))
end

function add_constructor(spec::SpecStruct)
    cconverted_members = getindex(spec.members, findall(is_semantic_ptr, spec.members.type))
    p = init_wrapper_func(spec)
    if needs_deps(spec)
        p[:body] = quote
            $((:($(var_from_vk(m.name)) = cconvert($(m.type), $(var_from_vk(m.name)))) for m ∈ cconverted_members)...)
            deps = [$((var_from_vk(m.name) for m ∈ cconverted_members)...)]
            vks = $(spec.name)($(map(vk_call, spec.members)...))
            $(p[:name])(vks, deps)
        end
    else
        p[:body] = :($(p[:name])($(spec.name)($(map(vk_call, spec.members)...))))
    end
    potential_args = filter(x -> x.type ≠ :VkStructureType, spec.members)
    add_func_args!(p, spec, potential_args)
    reconstruct(p)
end

function extend_from_vk(spec::SpecStruct)
    p = Dict(:category => :function, :name => :from_vk, :args => [:(T::Type{$(remove_vk_prefix(spec.name))}), :(x::$(spec.name))], :short => true)
    p[:body] = :(T($(filter(!isnothing, from_vk_call.(spec.members))...)))
    reconstruct(p)
end

function VulkanWrapper()
    handles = wrap.(spec_handles)
    structs = wrap.(spec_structs)
    returnedonly_structs = filter(x -> x.is_returnedonly, spec_structs)
    funcs = vcat(wrap.(spec_funcs), add_constructor.(filter(x -> !x.is_returnedonly, spec_structs)), extend_from_vk.(returnedonly_structs), add_constructor.(spec_handles_with_single_constructor))
    misc = []
    VulkanWrapper(handles, structs, funcs, misc)
end

is_optional(member::SpecStructMember) = member.name == :pNext || member.requirement ∈ [OPTIONAL, POINTER_OPTIONAL]
is_optional(param::SpecFuncParam) = param.requirement ∈ [OPTIONAL, POINTER_OPTIONAL]
is_count_variable(spec::Spec) = spec.type == :UInt32 && !isempty(spec.arglen)

"""
Represent an integer that gives the start of a C pointer.
"""
function is_pointer_start(spec::Spec)
    params = children(parent_spec(spec))
    any(params) do param
        !isempty(param.arglen) && spec.type == :UInt32 && string(spec.name) == string("first", uppercasefirst(replace(string(param.name), r"Count$" => "")))
    end
end

is_semantic_ptr(type) = is_ptr(type) || type == :Cstring
needs_deps(spec::SpecStruct) = any(is_semantic_ptr, spec.members.type)
