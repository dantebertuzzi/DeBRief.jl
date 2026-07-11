# Fonte Sinesp clássico — série histórica por UF, 2015–2022.
#
# LAYOUT DO ARQUIVO (inspecionado em julho/2026)
# ----------------------------------------------
# Recurso CKAN estável no portal de dados abertos do MJSP:
#   https://dados.mj.gov.br/dataset/210b9ae2-21fc-4986-89c6-2006eb4db247/
#     resource/feeae05e-faba-406c-8a4a-512aec91a9d1/download/
#     indicadoressegurancapublicauf.xlsx
#
# Planilha única com headers:
#   UF          :: String — nome POR EXTENSO ("Pernambuco"), não sigla
#   Tipo Crime  :: String — nove tipologias (ver SINESP_TYPOLOGIES)
#   Ano         :: Int
#   Mês         :: String — nome do mês em minúsculas ("janeiro"…"dezembro")
#   Ocorrências :: Int
#
# Unidade única (ocorrências), sem recorte municipal. Série encerrada em 2022
# com a migração para o Sinesp-VDE — as duas séries NÃO são emendadas.

const SINESP_FIRST_YEAR = 2015
const SINESP_LAST_YEAR = 2022
const SINESP_UF_URL =
    "https://dados.mj.gov.br/dataset/210b9ae2-21fc-4986-89c6-2006eb4db247/" *
    "resource/feeae05e-faba-406c-8a4a-512aec91a9d1/download/" *
    "indicadoressegurancapublicauf.xlsx"

"""
    _parse_sinesp(path) -> DataFrame

Parse the classic Sinesp UF spreadsheet into the normalized long schema.
Internal helper, unit-tested offline against the fixture in `test/data/`.
"""
function _parse_sinesp(path::AbstractString)
    xf = XLSX.readxlsx(path)
    sheet = xf[first(XLSX.sheetnames(xf))]
    raw = DataFrame(XLSX.gettable(sheet; infer_eltypes = true))
    rename!(raw, [n => _norm_header(n) for n in names(raw)])

    required = (:uf, :tipo_crime, :ano, :mes, :ocorrencias)
    missing_cols = [c for c in required if !hasproperty(raw, c)]
    if !isempty(missing_cols)
        error("DeBRief: unexpected layout in $(basename(path)) — missing column(s) " *
              "$(join(missing_cols, ", ")). Columns found: $(join(names(raw), ", ")).")
    end

    n = nrow(raw)
    date = Vector{Date}(undef, n)
    state = Vector{String}(undef, n)
    typology = Vector{String}(undef, n)
    value = Vector{Union{Missing,Int}}(undef, n)

    for i in 1:n
        m = get(MONTH_NAMES, normalize_key(raw.mes[i]), nothing)
        m === nothing && error("DeBRief: unknown month name $(repr(raw.mes[i])) " *
                               "in $(basename(path)).")
        y = _int(raw.ano[i])
        date[i] = Date(y, m, 1)
        state[i] = _resolve_uf(raw.uf[i])          # nome por extenso -> sigla
        typology[i] = match_typology(raw.tipo_crime[i], :sinesp)
        value[i] = _int(raw.ocorrencias[i])
    end

    df = DataFrame(; date, state, typology, value)
    df[!, :category] .= "occurrences"
    df[!, :measure] .= :occurrences
    # Colunas de sexo não existem na série clássica; mantemos o schema
    # compatível com o pós-processamento compartilhado usando missing
    df[!, :female] = fill(missing, n)
    df[!, :male] = fill(missing, n)
    df[!, :unspecified] = fill(missing, n)
    return select(df, :date, :state, :typology, :category, :measure,
                  :value, :female, :male, :unspecified)
end

function _assemble_sinesp(path::AbstractString;
                          state = nothing, year = nothing, typology = nothing,
                          granularity::Symbol = :month, relative::Bool = false,
                          geometry::Bool = false, progress::Bool = true)
    df = _parse_sinesp(path)

    years = _validate_years(year, SINESP_FIRST_YEAR, SINESP_LAST_YEAR, "classic Sinesp")
    subset!(df, :date => ByRow(d -> Dates.year(d) in years))
    _filter_states!(df, state)
    _filter_typologies!(df, typology, :sinesp)
    sort!(df, [:state, :typology, :date])

    df = _apply_granularity(df, granularity;
                            keys = [:state, :typology, :category, :measure])
    # A série clássica não tem colunas de sexo — remove as placeholders
    select!(df, Not([:female, :male, :unspecified]))

    if relative
        years_needed = unique(hasproperty(df, :year) ? df.year : Dates.year.(df.date))
        pops = Dict(y => _population_by_uf(y; progress) for y in years_needed)
        _add_rate!(df, pops, row -> row.state)
    end

    if geometry
        df = _attach_geometry(df, :state)
    end
    return df
end


"""
    fetch_sinesp(; state = nothing, year = nothing, typology = nothing,
                   granularity = :month, relative = false,
                   geometry = false, refresh = false, progress = true) -> DataFrame

Fetch the classic Sinesp historical series (MJSP): monthly occurrence counts
by state (UF) for nine crime typologies, $(SINESP_FIRST_YEAR)–$(SINESP_LAST_YEAR).
The raw spreadsheet is cached on disk (see [`clear_cache`](@ref)).

Keyword arguments mirror [`fetch_vde`](@ref) (no `municipality`/`category`:
this series is state-level with a single unit of measure). With
`relative = true`, `rate_100k` uses IBGE/SIDRA state population estimates.
With `geometry = true` (requires `using GeoDataFrames`), IBGE state meshes
are joined.

# Output schema
`date` (or `year`), `state`, `typology`, `category`, `measure` (always
`:occurrences`), `value`, and optionally `rate_100k`/`geometry`.

# Examples
```julia
julia> df = fetch_sinesp(state = "PE", typology = "roubo de veiculo");

julia> df = fetch_sinesp(year = 2022, granularity = :year, relative = true);
```

!!! note "Methodological break"
    This series ends in 2022 and precedes the Sinesp-VDE methodology
    ([`fetch_vde`](@ref)). The two series are deliberately **not** merged;
    see the *Data harmonization* page of the documentation.
"""
function fetch_sinesp(; state = nothing, year = nothing, typology = nothing,
                      granularity::Symbol = :month, relative::Bool = false,
                      geometry::Bool = false, refresh::Bool = false,
                      progress::Bool = true)
    path = _ensure_file(SINESP_UF_URL, "sinesp", "indicadoressegurancapublicauf.xlsx";
                        refresh, progress)
    return _assemble_sinesp(path; state, year, typology, granularity,
                            relative, geometry, progress)
end
