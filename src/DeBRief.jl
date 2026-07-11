"""
    DeBRief

Julia client for Brazilian crime and violence statistics published by the
Ministry of Justice and Public Security (MJSP) through the Sinesp platform.

Two independent data sources are exposed (they are **not** stitched together,
see the *Data harmonization* page of the documentation):

  - [`fetch_vde`](@ref):    Sinesp-VDE national database (2015–present),
    monthly, municipality-level, 28 indicators.
  - [`fetch_sinesp`](@ref): classic Sinesp historical series (2015–2022),
    monthly, state-level, 9 crime typologies.

Utilities: [`typologies`](@ref), [`clear_cache`](@ref), [`cache_info`](@ref).
"""
module DeBRief

using DataFrames
using Dates
using Downloads
using PooledArrays
using Scratch
using Serialization
using Unicode
using XLSX

export fetch_vde, fetch_sinesp, typologies, clear_cache, cache_info

include("cache.jl")
include("download.jl")
include("normalize.jl")
include("population.jl")
include("vde.jl")
include("sinesp.jl")
include("geometry.jl")

end # module DeBRief
