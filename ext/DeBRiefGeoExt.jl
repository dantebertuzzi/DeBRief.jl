# Extensão geoespacial (weak dependency em GeoJSON.jl), carregada
# automaticamente com `using GeoJSON, DeBRief`.
#
# Escolha de design: as malhas do IBGE (API v3) já são GeoJSON, então usamos
# o leitor puro-Julia GeoJSON.jl em vez da pilha GDAL (GeoDataFrames ->
# ArchGDAL -> GDAL_jll/PROJ_jll), que sofre com incompatibilidades binárias
# entre versões do Julia e pesa centenas de MB. As geometrias devolvidas
# implementam GeoInterface e plotam direto no Makie (poly!).
#
# Baixa as malhas com cache em disco — padrão análogo ao helper malha() dos
# projetos de mapas coropléticos — e implementa o método real de
# DeBRief._attach_geometry, habilitando `geometry = true` em fetch_vde e
# fetch_sinesp.

module DeBRiefGeoExt

using DeBRief
using GeoJSON
# DataFrames é dependência forte do DeBRief; acessamos pelo namespace do pai
using DeBRief.DataFrames: DataFrame, leftjoin, select!, transform!, ByRow, Not

const IBGE_MESH_BASE = "https://servicodados.ibge.gov.br/api/v3/malhas/"
const MESH_QUERY = "?formato=application/vnd.geo+json&qualidade=minima&intrarregiao="

"""
    malha(level::Symbol; states = nothing, progress = true) -> DataFrame

Download (or read from disk cache) IBGE meshes as a DataFrame with columns
`geometry` and `codarea`. `level` is `:state` (all 27 UFs) or `:municipality`
(pass the UF abbreviations to fetch in `states`). Internal to the extension.
"""
function malha(level::Symbol; states = nothing, progress::Bool = true)
    if level === :state
        # Malha nacional recortada por UF; codarea = código IBGE de 2 dígitos
        url = IBGE_MESH_BASE * "paises/BR" * MESH_QUERY * "UF"
        path = DeBRief._ensure_file(url, "malhas", "br_ufs.geojson"; progress)
        return _read_mesh(path)
    elseif level === :municipality
        states === nothing && error("malha(:municipality) requires `states`.")
        parts = DataFrame[]
        for uf in states
            code = DeBRief.UF_ABBREV_TO_CODE[uf]
            # Malha estadual recortada por município; codarea = 7 dígitos
            url = IBGE_MESH_BASE * "estados/$(code)" * MESH_QUERY * "municipio"
            path = DeBRief._ensure_file(url, "malhas", "municipios_$(uf).geojson"; progress)
            push!(parts, _read_mesh(path))
        end
        return vcat(parts...; cols = :union)
    end
    error("Unknown mesh level $(repr(level)); use :state or :municipality.")
end

# GeoJSON.read devolve uma FeatureCollection Tables.jl-compatível:
# vira DataFrame com :geometry + propriedades (codarea) direto
function _read_mesh(path::AbstractString)
    fc = GeoJSON.read(read(path, String))
    mesh = DataFrame(fc)
    # Padroniza o nome da coluna de geometria entre versões do GeoJSON.jl
    if !hasproperty(mesh, :geometry)
        old = hasproperty(mesh, :geom) ? :geom : Symbol(first(names(mesh)))
        DeBRief.DataFrames.rename!(mesh, old => :geometry)
    end
    hasproperty(mesh, :codarea) ||
        error("DeBRief: IBGE mesh at $(basename(path)) has no `codarea` property; " *
              "the API format may have changed. Columns found: $(join(names(mesh), ", ")).")
    return mesh
end

function DeBRief._attach_geometry(df::DataFrame, level::Symbol)
    if level === :state
        mesh = malha(:state)
        # codarea vem como String de 2 dígitos; mapeia sigla -> código p/ join
        transform!(mesh, :codarea => ByRow(c -> parse(Int, string(c))) => :_uf_code)
        transform!(df, :state => ByRow(s -> DeBRief.UF_ABBREV_TO_CODE[s]) => :_uf_code)
        out = leftjoin(df, select!(mesh, :_uf_code, :geometry), on = :_uf_code)
        select!(out, Not(:_uf_code))
        return out
    elseif level === :municipality
        # fetch_vde já adicionou :municipality_code via _add_municipality_code!
        mesh = malha(:municipality; states = unique(df.state))
        transform!(mesh, :codarea => ByRow(c -> parse(Int, string(c))) => :municipality_code)
        # matchmissing: linhas cujo código não foi resolvido ficam sem geometria
        return leftjoin(df, select!(mesh, :municipality_code, :geometry),
                        on = :municipality_code, matchmissing = :notequal)
    end
    error("Unknown geometry level $(repr(level)).")
end

end # module DeBRiefGeoExt
