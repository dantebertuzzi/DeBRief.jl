# Cache em disco via Scratch.jl — mesmo padrão do ElectionsBR.jl.
# Todo arquivo bruto baixado (XLSX do Sinesp, JSON do SIDRA, malhas GeoJSON)
# vive dentro do scratch space do pacote; o parsing SEMPRE parte do arquivo
# em cache. `clear_cache()` apaga tudo e força novo download.

# Diretório-raiz do cache (criado sob demanda)
_cache_root() = @get_scratch!("cache")

"""
    cache_path(parts...) -> String

Return the absolute path of a cached file, creating intermediate
directories as needed. Internal helper — not part of the public API.
"""
function cache_path(parts::AbstractString...)
    # Garante os subdiretórios intermediários antes de devolver o caminho
    path = joinpath(_cache_root(), parts...)
    mkpath(dirname(path))
    return path
end

"""
    clear_cache()

Delete every file cached by DeBRief (raw Sinesp spreadsheets, SIDRA
population responses and IBGE meshes). The next call to [`fetch_vde`](@ref)
or [`fetch_sinesp`](@ref) will download fresh copies.

# Examples
```julia
julia> clear_cache()
```
"""
function clear_cache()
    root = _cache_root()
    # Remove e recria a raiz — mais simples do que iterar arquivo a arquivo
    rm(root; force = true, recursive = true)
    mkpath(root)
    return nothing
end

"""
    cache_info() -> DataFrame

List every file in DeBRief's disk cache (raw Sinesp spreadsheets, SIDRA
population responses, IBGE meshes and partial downloads) with its size in
MiB, largest first. Sum the `mb` column for the total footprint; use
[`clear_cache`](@ref) to delete everything.

# Examples
```julia
julia> info = cache_info();

julia> sum(info.mb)   # total em MiB
```
"""
function cache_info()
    root = _cache_root()
    rows = NamedTuple{(:file, :mb),Tuple{String,Float64}}[]
    # Percorre o scratch inteiro, inclusive .part de downloads interrompidos
    for (dir, _, files) in walkdir(root), f in files
        p = joinpath(dir, f)
        push!(rows, (file = relpath(p, root), mb = round(filesize(p) / 2^20; digits = 2)))
    end
    df = DataFrame(rows)
    return sort!(df, :mb, rev = true)
end
