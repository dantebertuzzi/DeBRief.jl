# Extensão geoespacial (weak dependency em GeoDataFrames), carregada
# automaticamente com `using GeoDataFrames, DeBRief`.
#
# Baixa as malhas do IBGE (API v3 de malhas, GeoJSON com qualidade mínima)
# com cache em disco — padrão análogo ao helper malha() usado nos projetos
# de mapas coropléticos com dados do DATASUS — e implementa o método real de
# DeBRief._attach_geometry, habilitando `geometry = true` em fetch_vde e
# fetch_sinesp.

module DeBRiefGeoExt

using DeBRief
using GeoDataFrames
# DataFrames é dependência forte do DeBRief; acessamos pelo namespace do pai
using DeBRief.DataFrames: DataFrame, leftjoin, select!, transform!, ByRow, Not, nrow

const IBGE_MESH_BASE = "https://servicodados.ibge.gov.br/api/v3/malhas/"
const MESH_QUERY = "?formato=application/vnd.geo+json&qualidade=minima&intrarregiao="

"""
    malha(level::Symbol; states = nothing, progress = true) -> DataFrame

Download (or read from disk cache) IBGE meshes as a GeoDataFrame with columns
`geometry` and `codarea`. `level` is `:state` (all 27 UFs) or `:municipality`
(pass the UF abbreviations to fetch in `states`). Internal to the extension.
"""
function malha(level::Symbol; states = nothing, progress::Bool = true)
    if level === :state
        # Malha nacional recortada por UF; codarea = código IBGE de 2 dígitos
        url = IBGE_MESH_BASE * "paises/BR" * MESH_QUERY * "UF"
        path = DeBRief._ensure_file(url, "malhas", "br_ufs.geojson"; progress)
        return GeoDataFrames.read(path)
    elseif level === :municipality
        states === nothing && error("malha(:municipality) requires `states`.")
        parts = DataFrame[]
        for uf in states
            code = DeBRief.UF_ABBREV_TO_CODE[uf]
            # Malha estadual recortada por município; codarea = código de 7 dígitos
            url = IBGE_MESH_BASE * "estados/$(code)" * MESH_QUERY * "municipio"
            path = DeBRief._ensure_file(url, "malhas", "municipios_$(uf).geojson"; progress)
            push!(parts, GeoDataFrames.read(path))
        end
        return vcat(parts...; cols = :union)
    end
    error("Unknown mesh level $(repr(level)); use :state or :municipality.")
end

# O nome da coluna de geometria variou entre versões do GeoDataFrames
# ("geom" -> "geometry"); padroniza para :geometry
function _std_geocol!(mesh::DataFrame)
    if !hasproperty(mesh, :geometry)
        old = hasproperty(mesh, :geom) ? :geom : Symbol(first(names(mesh)))
        DeBRief.DataFrames.rename!(mesh, old => :geometry)
    end
    return mesh
end

function DeBRief._attach_geometry(df::DataFrame, level::Symbol)
    if level === :state
        mesh = _std_geocol!(malha(:state))
        # codarea vem como String de 2 dígitos; mapeia sigla -> código para o join
        transform!(mesh, :codarea => ByRow(c -> parse(Int, c)) => :_uf_code)
        transform!(df, :state => ByRow(s -> DeBRief.UF_ABBREV_TO_CODE[s]) => :_uf_code)
        out = leftjoin(df, select!(mesh, :_uf_code, :geometry), on = :_uf_code)
        select!(out, Not(:_uf_code))
        return out
    elseif level === :municipality
        # fetch_vde já adicionou :municipality_code via DeBRief._add_municipality_code!
        mesh = _std_geocol!(malha(:municipality; states = unique(df.state)))
        transform!(mesh, :codarea => ByRow(c -> parse(Int, c)) => :municipality_code)
        # matchmissing: linhas cujo código não foi resolvido ficam sem geometria
        return leftjoin(df, select!(mesh, :municipality_code, :geometry),
                        on = :municipality_code, matchmissing = :notequal)
    end
    error("Unknown geometry level $(repr(level)).")
end

end # module DeBRiefGeoExt
