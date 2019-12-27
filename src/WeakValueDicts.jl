module WeakValueDicts

export WeakValueDict

using Base: Callable, ValueIterator, secret_table_token

"""
    WeakValueDict([itr])

`WeakValueDict()` constructs a hash table where the values are weak references
to objects which may be garbage collected even when referenced in a hash table.

See [`Dict`](@ref) for further help.
"""
mutable struct WeakValueDict{K,V} <: AbstractDict{K,V}
    ht::Dict{K,WeakRef}
    lock::ReentrantLock
    finalizer

    # Constructors mirror Dict's
    function WeakValueDict{K,V}() where {K,V}
        if isimmutable(V)
            error("WeakValueDict cannot be used with immutable values.")
        end
        wvd = new(Dict{Any,V}(), ReentrantLock())
        wvd.finalizer = function (k, v)
            # When a weak value is finalized, remove from dictionary if it is
            # still there.
            if islocked(wvd)
                # If locked, we add another finalizer and defer the deletion
                # until the new finalizer is invoked.
                finalizer(wvd.finalizer, k)
                return nothing
            end
            delete!(wvd, k)
        end
        return wvd
    end
end

function WeakValueDict{K,V}(kv) where {K,V}
    h = WeakValueDict{K,V}()
    for (k, v) in kv
        h[k] = v
    end
    return h
end

function WeakValueDict{K,V}(p::Pair) where {K,V}
    setindex!(WeakValueDict{K,V}(), p.second, p.first)
end

function WeakValueDict{K,V}(ps::Pair...) where {K,V}
    h = WeakValueDict{K,V}()
    sizehint!(h, length(ps))
    for p in ps
        h[p.first] = p.second
    end
    return h
end
WeakValueDict() = WeakValueDict{Any,Any}()

WeakValueDict(kv::Tuple{}) = WeakValueDict()
Base.copy(d::WeakValueDict) = WeakValueDict(d)

WeakValueDict(ps::Pair{K,V}...) where {K,V} = WeakValueDict{K,V}(ps)
WeakValueDict(ps::Pair{K}...) where {K} = WeakValueDict{K,Any}(ps)
WeakValueDict(ps::(Pair{K,V} where {K})...) where {V} = WeakValueDict{Any,V}(ps)
WeakValueDict(ps::Pair...) = WeakValueDict{Any,Any}(ps)

function WeakValueDict(kv)
    try
        Base.dict_with_eltype((K, V) -> WeakValueDict{K,V}, kv, eltype(kv))
    catch
        if !isiterable(typeof(kv)) || !all(x -> isa(x, Union{Tuple,Pair}), kv)
            throw(ArgumentError(
                "WeakValueDict(kv): " *
                    "kv needs to be an iterator of tuples or pairs",
            ))
        else
            rethrow()
        end
    end
end

function Base.empty(d::WeakValueDict, ::Type{K}, ::Type{V}) where {K,V}
    return WeakValueDict{K,V}()
end

Base.islocked(wvd::WeakValueDict) = islocked(wvd.lock)
Base.lock(f, wvd::WeakValueDict) = lock(f, wvd.lock)
Base.trylock(f, wvd::WeakValueDict) = trylock(f, wvd.lock)

function Base.getindex(wvd::WeakValueDict{K, V}, key::K)::V where {K, V}
    return lock(wvd) do
        return getindex(wvd.ht, key).value::V
    end
end

function Base.setindex!(wvd::WeakValueDict{K, V}, value::V, key::K) where {K,V}
    finalizer((value) -> wvd.finalizer(key, value), value)
    lock(wvd) do
        wvd.ht[key] = WeakRef(value)
    end
    return wvd
end

function Base.getkey(wvd::WeakValueDict{K}, kk, default) where {K}
    return lock(wvd) do
        k = getkey(wvd.ht, kk, secret_table_token)
        k === secret_table_token && return default
        return k
    end
end

function map!(f, iter::ValueIterator{<:WeakValueDict})
    dict = iter.dict
    vals = dict.vals
    # @inbounds is here so the it gets propigated to isslotfiled
    @inbounds for i = dict.idxfloor:lastindex(vals)
        if isslotfilled(dict, i)
            # Hold an explicit reference here so that we avoid race conditions
            # where the GC can trigger between checking if the value is
            # `nothing` and actually mapping it.
            value = vals[i].value
            if value === nothing
                continue
            end
            vals[i].value = f(value)
        end
    end
    return iter
end

function Base.get(wvd::WeakValueDict{K}, key, default) where {K}
    return get(() -> default, wvd, key)
end

function Base.get(default::Callable, wvd::WeakValueDict{K, V}, key) where {K, V}
    return lock(wvd) do
        if haskey(wvd.ht, key)
            return wvd.ht[key].value::V
        end
        return default()
    end
end

function Base.get!(wvd::WeakValueDict{K, V}, key::K, default::V) where {K,V}
    return get!(() -> default, wvd, key)
end

function Base.get!(default::Callable, wvd::WeakValueDict{K, V}, key::K) where {K,V}
    return lock(wvd) do
        if haskey(wvd.ht, key)
            value = wvd.ht[key].value
            if value !== nothing
                return value
            end
        end
        return (wvd[key] = default()::V)
    end
end

function Base.pop!(wvd::WeakValueDict{K, V}, key)::V where {K,V}
    return lock(wvd) do
        ref = pop!(wvd.ht, key)
        # TODO: Can this ever be nothing? Can a WeakRef's value be nothing
        # before the finalizers run?
        return ref.value::V
    end
end

function Base.pop!(wvd::WeakValueDict{K, V}, key, default) where {K, V}
    return lock(wvd) do
        if haskey(wvd.ht)
            ref = pop!(wvd.ht, key)
            return ref.value::V
        end
        return default
    end
end

function Base.delete!(wvd::WeakValueDict, key)
    lock(wvd) do
        delete!(wvd.ht, key)
        return wvd
    end
end
Base.empty!(wvd::WeakValueDict) = (lock(() -> empty!(wvd.ht), wvd); wvd)
Base.haskey(wvd::WeakValueDict{K}, key) where {K} =
    lock(() -> haskey(wvd.ht, key), wvd)

Base.isempty(wvd::WeakValueDict) = isempty(wvd.ht)
Base.length(t::WeakValueDict) = length(t.ht)

function Base.iterate(t::WeakValueDict{K,V}, state...) where {K,V}
    y = lock(() -> iterate(t.ht, state...), t)
    y === nothing && return nothing
    wkv, newstate = y
    key, value_ref = wkv
    kv = Pair{K,V}(key, value_ref.value::V)
    return (kv, newstate)
end

Base.filter!(f, d::WeakValueDict) = filter_in_one_pass!(f, d)

end # module