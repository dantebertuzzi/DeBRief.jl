# Ganchos de integração geoespacial. A implementação real vive na extensão
# DeBRiefGeoExt (ext/DeBRiefGeoExt.jl), carregada automaticamente quando o
# usuário faz `using GeoDataFrames` — padrão de weak dependency para manter
# o core do pacote sem dependências geoespaciais.

"""
    _attach_geometry(df, level::Symbol) -> DataFrame

Join IBGE meshes (`level` is `:state` or `:municipality`) onto `df`.
The fallback method below only reports how to enable the feature; the real
implementation is provided by the `DeBRiefGeoExt` package extension.
"""
function _attach_geometry(df, level)
    error("DeBRief: `geometry = true` requires the GeoDataFrames package. " *
          "Install it (`] add GeoDataFrames`) and load it before fetching:\n" *
          "    using GeoDataFrames, DeBRief\n" *
          "This activates the DeBRiefGeoExt package extension.")
end

"""
    _add_municipality_code!(df; progress = true) -> DataFrame

Add a `municipality_code` column (7-digit IBGE code, `missing` when the name
cannot be resolved) using the registry derived from SIDRA. The VDE source
files carry only municipality NAMES, so this resolution is by normalized
name + UF. Internal helper used by the geo extension join.
"""
function _add_municipality_code!(df::DataFrame; progress::Bool = true)
    _, byname = _municipality_lookup(; progress)
    codes = Vector{Union{Missing,Int}}(undef, nrow(df))
    misses = 0
    for i in 1:nrow(df)
        code = get(byname, normalize_key(df.municipality[i]) * "|" * df.state[i], nothing)
        codes[i] = code === nothing ? missing : code
        code === nothing && (misses += 1)
    end
    misses > 0 && @warn "DeBRief: could not resolve the IBGE code of $misses row(s) " *
                        "by municipality name; their geometry will be missing."
    df[!, :municipality_code] = codes
    return df
end
