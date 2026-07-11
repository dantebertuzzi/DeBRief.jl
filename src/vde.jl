# Fonte Sinesp-VDE (Dados Nacionais de Segurança Pública), 2015–presente.
#
# LAYOUT DOS ARQUIVOS (inspecionado em julho/2026)
# ------------------------------------------------
# Um XLSX por ano, publicado pelo MJSP em páginas Plone do gov.br:
#   https://www.gov.br/mj/pt-br/assuntos/sua-seguranca/seguranca-publica/
#     estatistica/download/dnsp-base-de-dados/bancovde-{ANO}.xlsx/@@download/file
# (anos disponíveis: 2015 até o corrente; a página "Base de Dados e Notas
# Metodológicas dos Gestores Estaduais - Sinesp VDE" lista todos os links).
#
# Cada arquivo tem uma única planilha com headers em snake_case minúsculo:
#   uf              :: String  — sigla ("PE")
#   municipio       :: String  — NOME do município (não há código IBGE!)
#   evento          :: String  — tipologia; vocabulário deriva entre anos
#   data_referencia :: Date/serial Excel — mês de referência
#   agente          :: String? — só em indicadores de agente do Estado
#   arma            :: String? — desagregação de armas apreendidas
#   faixa_etaria    :: String? — só em desaparecidos/localizados
#   feminino, masculino, nao_informado :: Int? — vítimas por sexo
#   total           :: Int?    — ocorrências/unidades/atendimentos
#   total_peso      :: Float?  — quilos (apreensões de drogas)
#   total_vitima    :: Int?    — total de vítimas
#   abrangencia     :: String  — escopo do registro (não exposto no schema)
#
# Pegadinha documentada pelo próprio MJSP: em "Tentativa de Homicídio" e
# "Estupro" um mesmo município-mês pode aparecer em DUAS linhas, que devem
# ser somadas — a agregação em `_parse_vde` resolve isso de forma geral.

const VDE_FIRST_YEAR = 2015
const VDE_URL_PREFIX = "https://www.gov.br/mj/pt-br/assuntos/sua-seguranca/" *
    "seguranca-publica/estatistica/download/dnsp-base-de-dados/"

_vde_url(year::Integer) = VDE_URL_PREFIX * "bancovde-$(year).xlsx/@@download/file"

# Colunas obrigatórias para considerar o layout reconhecido
const _VDE_REQUIRED = (:uf, :municipio, :evento, :data_referencia)

# Colunas de valor por unidade de medida (ver normalize.jl)
_value_column(measure::Symbol) = measure === :victims ? :total_vitima :
                                 measure === :kg      ? :total_peso   : :total

# ---------------------------------------------------------------------------
# Parsing de um arquivo anual

# Leitura em streaming (enable_cache = false): o cache de células do XLSX.jl
# multiplica por várias vezes o tamanho dos bancovde grandes na RAM e é a
# causa clássica de travamento ao carregar todos os anos de uma vez.
function _read_first_sheet(path::AbstractString)
    XLSX.openxlsx(path; enable_cache = false) do xf
        sheet = xf[first(XLSX.sheetnames(xf))]
        DataFrame(XLSX.gettable(sheet; infer_eltypes = true))
    end
end

"""
    _parse_vde(path, year) -> DataFrame

Parse one annual `bancovde-{year}.xlsx` file into the normalized long
schema (`date, state, municipality, typology, category, measure, value,
female, male, unspecified`), summing duplicated (municipality, month,
typology) rows as instructed by the MJSP. Internal helper, unit-tested
offline against the fixture in `test/data/`.
"""
function _parse_vde(path::AbstractString, year::Integer)
    xf = XLSX.readxlsx(path)
    sheet = xf[first(XLSX.sheetnames(xf))]
    # Sem infer_eltypes: a inferência de tipos do XLSX.jl é muito cara nos
    # arquivos grandes e as coerções abaixo já tratam célula a célula
    raw = DataFrame(XLSX.gettable(sheet))
    rename!(raw, [n => _norm_header(n) for n in names(raw)])

    # Guarda contra mudança de layout: erro claro listando o que foi achado
    missing_cols = [c for c in _VDE_REQUIRED if !hasproperty(raw, c)]
    if !isempty(missing_cols)
        error("DeBRief: unexpected layout in $(basename(path)) — missing column(s) " *
              "$(join(missing_cols, ", ")). Columns found: $(join(names(raw), ", ")). " *
              "The upstream file format may have changed; please open an issue.")
    end
    # Colunas de valor podem faltar em recortes/anos antigos — completa com missing
    for c in (:feminino, :masculino, :nao_informado, :total, :total_peso, :total_vitima)
        hasproperty(raw, c) || (raw[!, c] = fill(missing, nrow(raw)))
    end

    n = nrow(raw)
    date = Vector{Date}(undef, n)
    state = Vector{String}(undef, n)
    municipality = Vector{String}(undef, n)
    typology = Vector{String}(undef, n)
    category = Vector{String}(undef, n)
    measure = Vector{Symbol}(undef, n)
    value = Vector{Union{Missing,Int,Float64}}(undef, n)
    female = Vector{Union{Missing,Int}}(undef, n)
    male = Vector{Union{Missing,Int}}(undef, n)
    unspecified = Vector{Union{Missing,Int}}(undef, n)

    # Memoização por arquivo: os vocabulários de uf/município/evento são
    # pequenos e se repetem milhões de vezes nos anos grandes — evita
    # renormalizar (Unicode) a mesma string linha a linha
    uf_cache = Dict{String,String}()
    mun_cache = Dict{String,String}()
    typ_cache = Dict{String,Union{Typology,Nothing}}()

    for i in 1:n
        date[i] = _refmonth(raw.data_referencia[i])
        # UF vem como sigla; se algum ano trouxer o nome por extenso, resolve igual
        ufraw = string(raw.uf[i])
        state[i] = get!(() -> _resolve_uf(ufraw), uf_cache, ufraw)
        mraw = string(raw.municipio[i])
        municipality[i] = get!(() -> String(strip(mraw)), mun_cache, mraw)
        eraw = string(raw.evento[i])
        typ = get!(() -> _canonical_typology(eraw, year), typ_cache, eraw)
        if typ === nothing
            # Indicador desconhecido (compatibilidade futura): mantém o nome
            # bruto, categoria "other" e escolhe a coluna de valor preenchida
            typology[i] = String(strip(string(raw.evento[i])))
            category[i] = "other"
            measure[i] = !ismissing(raw.total_vitima[i]) ? :victims :
                         !ismissing(raw.total_peso[i])   ? :kg : :occurrences
        else
            typology[i] = typ.name
            category[i] = typ.category
            measure[i] = typ.measure
        end

        female[i] = _int(raw.feminino[i])
        male[i] = _int(raw.masculino[i])
        unspecified[i] = _int(raw.nao_informado[i])

        vcol = _value_column(measure[i])
        if measure[i] === :kg
            value[i] = _float(raw[i, vcol])
        elseif measure[i] === :victims || measure[i] === :people
            # Nos formulários de vítimas e de desaparecidos/localizados a
            # fonte oscila entre preencher a coluna-alvo, a alternativa
            # (total x total_vitima) ou APENAS as colunas por sexo, deixando
            # a coluna-alvo zerada — observado nos arquivos reais de 2025,
            # onde `total` de Pessoa Desaparecida vem 0 no país inteiro.
            # Usa a primeira contagem não-vazia e não-zero da cadeia; se tudo
            # for zero, zero é o valor legítimo (painel completo).
            alt = vcol === :total_vitima ? :total : :total_vitima
            sexsum = _sumskip(Union{Missing,Int}[female[i], male[i], unspecified[i]])
            value[i] = _first_count(_int(raw[i, vcol]), _int(raw[i, alt]), sexsum)
        else
            value[i] = _int(raw[i, vcol])
        end
    end

    # Colunas categóricas em PooledArray: nos anos grandes (centenas de
    # milhares de linhas) isso reduz memória em ordem de grandeza e acelera
    # o groupby/vcat do pipeline
    df = DataFrame(; date,
                   state = PooledArray(state),
                   municipality = PooledArray(municipality),
                   typology = PooledArray(typology),
                   category = PooledArray(category),
                   measure = PooledArray(measure),
                   value, female, male, unspecified)

    # Soma linhas duplicadas de um mesmo município-mês-tipologia (nota oficial
    # do MJSP para Tentativa de Homicídio e Estupro; aplicada de forma geral)
    gd = groupby(df, [:date, :state, :municipality, :typology, :category, :measure])
    out = combine(gd,
                  :value => _sumskip => :value,
                  :female => _sumskip => :female,
                  :male => _sumskip => :male,
                  :unspecified => _sumskip => :unspecified)
    return _narrow_value!(out)
end

# ---------------------------------------------------------------------------
# Cache de segundo nível: o parse do XLSX é o gargalo (minutos por ano nos
# arquivos grandes). O DataFrame normalizado de cada ano é serializado no
# scratch e reutilizado — o custo do XLSX é pago UMA vez por arquivo baixado.
# Incrementar PARSER_VERSION quando a normalização mudar de forma
# incompatível invalida os caches antigos automaticamente.

const PARSER_VERSION = 2  # v2: cadeia de fallback p/ :victims e :people

"""
    _parse_vde_cached(path, year; progress = true) -> DataFrame

Memoized-on-disk version of [`_parse_vde`](@ref): the normalized `DataFrame`
is serialized under the package scratch space, keyed by year, file size and
`PARSER_VERSION`. Stale or incompatible caches (e.g. written by another
Julia version) are transparently discarded and rebuilt. Internal helper.
"""
function _parse_vde_cached(path::AbstractString, year::Integer;
                           progress::Bool = true)
    key = "bancovde-$(year)-v$(PARSER_VERSION)-$(filesize(path)).jls"
    cached = cache_path("vde_parsed", key)
    if isfile(cached)
        try
            return deserialize(cached)::DataFrame
        catch
            rm(cached; force = true)  # cache de outra versão de Julia/pacotes
        end
    end
    progress && @info "DeBRief: parsing bancovde-$(year).xlsx " *
                      "(slow on first use; cached afterwards)"
    df = _parse_vde(path, year)
    try
        serialize(cached, df)
    catch
        # Falha ao gravar cache não é fatal — só perde a memoização
    end
    return df
end

# ---------------------------------------------------------------------------
# Filtros e pós-processamento (compartilhados com fetch_sinesp onde faz sentido)

_asvector(x) = x isa AbstractVector ? collect(x) : [x]

function _validate_years(year, first_year::Int, last_year::Int, source::String)
    year === nothing && return collect(first_year:last_year)
    ys = year isa AbstractRange ? collect(year) : _asvector(year)
    all(y -> y isa Integer, ys) ||
        throw(ArgumentError("`year` must be an Int, a Vector{Int} or a range."))
    ys = Int.(ys)
    bad = filter(y -> !(first_year <= y <= last_year), ys)
    isempty(bad) || throw(ArgumentError(
        "Year(s) $(join(bad, ", ")) outside the $(source) coverage " *
        "($(first_year)-$(last_year))."))
    return sort(unique(ys))
end

function _filter_states!(df::DataFrame, state)
    state === nothing && return df
    keep = Set(_resolve_uf.(_asvector(state)))
    return subset!(df, :state => ByRow(in(keep)))
end

function _filter_typologies!(df::DataFrame, typology, source::Symbol)
    typology === nothing && return df
    keep = Set(match_typology.(_asvector(typology), source))
    return subset!(df, :typology => ByRow(in(keep)))
end

"""
    _municipality_keys(municipality; progress = true) -> Union{Nothing,Set{String}}

Resolve the `municipality` filter (names or IBGE codes) into a set of
normalized name keys, or `nothing` when absent. Internal helper.
"""
function _municipality_keys(municipality; progress::Bool = true)
    municipality === nothing && return nothing
    ms = _asvector(municipality)
    names_ = String[]
    if all(m -> m isa Integer, ms)
        # Código IBGE: resolve para nome via registro derivado do SIDRA
        bycode, _ = _municipality_lookup(; progress)
        for m in ms
            haskey(bycode, Int(m)) || throw(ArgumentError(
                "Unknown IBGE municipality code $m."))
            push!(names_, bycode[Int(m)][1])
        end
    elseif all(m -> m isa AbstractString, ms)
        append!(names_, string.(ms))
    else
        throw(ArgumentError(
            "`municipality` must be all names (String) or all IBGE codes (Int); " *
            "mixing both is not supported."))
    end
    return Set(normalize_key.(names_))
end

function _apply_granularity(df::DataFrame, granularity::Symbol; keys::Vector{Symbol})
    granularity in (:month, :year) ||
        throw(ArgumentError("`granularity` must be :month or :year."))
    granularity === :month && return df
    df = transform(df, :date => ByRow(Dates.year) => :year)
    gd = groupby(df, vcat(:year, keys))
    out = combine(gd,
                  :value => _sumskip => :value,
                  :female => _sumskip => :female,
                  :male => _sumskip => :male,
                  :unspecified => _sumskip => :unspecified)
    _narrow_value!(out)
    return sort!(out, vcat(keys, :year))
end

# Adiciona rate_100k usando um lookup (chave -> população). `keyfun` extrai a
# chave de cada linha; `yearfun` o ano de referência da população.
function _add_rate!(df::DataFrame, pops::Dict{Int,<:AbstractDict}, keyfun::Function)
    yearcol = hasproperty(df, :year) ? df.year : Dates.year.(df.date)
    rate = Vector{Union{Missing,Float64}}(undef, nrow(df))
    misses = 0
    for i in 1:nrow(df)
        pop = get(pops[yearcol[i]], keyfun(df[i, :]), nothing)
        if pop === nothing || ismissing(df.value[i])
            rate[i] = missing
            pop === nothing && (misses += 1)
        else
            rate[i] = df.value[i] / pop * 100_000
        end
    end
    misses > 0 && @warn "DeBRief: population not found for $misses row(s); " *
                        "`rate_100k` is `missing` there."
    df[!, :rate_100k] = all(!ismissing, rate) ? Float64.(rate) : rate
    return df
end

# ---------------------------------------------------------------------------
# Montagem (separada do download para permitir testes offline com fixtures)

function _assemble_vde(paths::Dict{Int,String};
                       state = nothing, municipality = nothing, year = nothing,
                       typology = nothing, category = nothing,
                       granularity::Symbol = :month, relative::Bool = false,
                       geometry::Bool = false, progress::Bool = true)
    # Valida e pré-resolve TODOS os filtros antes de qualquer parsing: erros
    # de argumento saem em milissegundos, e os filtros são aplicados ano a
    # ano (pushdown) para manter o pico de memória em ~1 arquivo por vez
    granularity in (:month, :year) ||
        throw(ArgumentError("`granularity` must be :month or :year."))
    states = state === nothing ? nothing : Set(_resolve_uf.(_asvector(state)))
    typs = typology === nothing ? nothing :
           Set(match_typology.(_asvector(typology), :vde))
    cats = nothing
    if category !== nothing
        keys_ = normalize_key.(_asvector(category))
        bad = filter(k -> !(k in VDE_CATEGORIES), keys_)
        isempty(bad) || throw(ArgumentError(
            "Unknown category $(join(repr.(bad), ", ")). Valid options: " *
            join(VDE_CATEGORIES, ", ") * "."))
        cats = Set(keys_)
    end
    years = year === nothing ? nothing :
            Set(_validate_years(year, VDE_FIRST_YEAR, maximum(keys(paths)),
                                "Sinesp-VDE"))
    munkeys = _municipality_keys(municipality; progress)

    parts = DataFrame[]
    for (y, p) in sort(collect(paths); by = first)
        progress && @info "DeBRief: parsing $(basename(p)) (large years can take a minute)"
        d = _parse_vde(p, y)
        # Ordem dos filtros: dos mais seletivos/baratos para os mais caros
        years !== nothing && subset!(d, :date => ByRow(dt -> Dates.year(dt) in years))
        states !== nothing && subset!(d, :state => ByRow(in(states)))
        munkeys !== nothing &&
            subset!(d, :municipality => ByRow(m -> normalize_key(m) in munkeys))
        typs !== nothing && subset!(d, :typology => ByRow(in(typs)))
        cats !== nothing && subset!(d, :category => ByRow(in(cats)))
        push!(parts, d)
        # Libera o arquivo anterior antes de abrir o próximo ano grande
        length(paths) > 1 && GC.gc()
    end
    df = reduce(vcat, parts)

    # Nomes de municípios NÃO são únicos no Brasil (ex.: "Bom Jesus" existe
    # em cinco UFs) e a fonte não traz código IBGE — avisa quando o filtro
    # por nome casa mais de uma UF
    if munkeys !== nothing
        ufs = unique(df.state)
        if length(ufs) > 1
            @warn "DeBRief: municipality filter matched more than one state " *
                  "($(join(sort(ufs), ", "))). Municipality names are ambiguous in " *
                  "Brazil; combine with the `state` keyword to disambiguate."
        end
    end
    sort!(df, [:state, :municipality, :typology, :date])

    df = _apply_granularity(df, granularity;
                            keys = [:state, :municipality, :typology, :category, :measure])

    if relative
        years_needed = unique(hasproperty(df, :year) ? df.year : Dates.year.(df.date))
        pops = Dict(y => _population_by_municipality(y; progress) for y in years_needed)
        _add_rate!(df, pops, row -> normalize_key(row.municipality) * "|" * row.state)
    end

    if geometry
        _add_municipality_code!(df; progress)
        df = _attach_geometry(df, :municipality)
    end
    return df
end

# ---------------------------------------------------------------------------
# API pública

"""
    fetch_vde(; state = nothing, municipality = nothing, year = nothing,
                typology = nothing, category = nothing,
                granularity = :month, relative = false,
                geometry = false, refresh = false, progress = true) -> DataFrame

Fetch the Sinesp-VDE national public security database (MJSP), monthly and
municipality-level, from $(VDE_FIRST_YEAR) to the most recent available year.
Raw annual spreadsheets are cached on disk (see [`clear_cache`](@ref)).

# Keyword arguments
- `state`: UF abbreviation or full name, or a vector (`"PE"`, `["PE", "BA"]`).
- `municipality`: municipality name(s) or IBGE code(s). Municipality **names
  are not unique across Brazil**; the source files carry no IBGE code, so a
  name filter may match several states — combine with `state`, or pass IBGE
  codes, to disambiguate.
- `year`: `Int`, `Vector{Int}` or range within $(VDE_FIRST_YEAR)–present.
- `typology`: canonical indicator name(s); matching is case- and
  accent-insensitive (`"homicidio doloso"` works). See [`typologies`](@ref).
- `category`: one of `$(join(VDE_CATEGORIES, ", "))`.
- `granularity`: `:month` (default) or `:year` (sums within the year).
- `relative`: when `true`, adds `rate_100k` (per 100k inhabitants) using
  IBGE/SIDRA population estimates for the matching year (no monthly
  interpolation in v0.1.0). Rows whose population cannot be resolved get
  `missing`.
- `geometry`: when `true`, joins IBGE municipal meshes; requires loading
  GeoJSON first (`using GeoJSON`) to activate the package
  extension.
- `refresh`: force re-download of the cached spreadsheets (useful for the
  current year, which is updated monthly).
- `progress`: print download and parsing progress messages.

!!! warning "Full unfiltered fetch is heavy"
    With no filters this returns the complete panel — every municipality ×
    month × indicator since $(VDE_FIRST_YEAR), millions of rows. Files are
    read in streaming mode and filters are pushed down into the per-year
    loop, so memory stays bounded, but parsing all years still takes several
    minutes. For interactive work, filter by `year`/`state` first.

# Output schema
One row per municipality × month × typology:

| column         | type                        | description                        |
|:---------------|:----------------------------|:-----------------------------------|
| `date`         | `Date`                      | first day of the reference month (`:month` only) |
| `year`         | `Int`                       | reference year (`:year` only)      |
| `state`        | `String`                    | UF abbreviation                    |
| `municipality` | `String`                    | municipality name as published     |
| `typology`     | `String`                    | canonical indicator name           |
| `category`     | `String`                    | analytic grouping                  |
| `measure`      | `Symbol`                    | unit: `:victims`, `:occurrences`, `:kg`, `:units`, `:people`, `:warrants`, `:services` |
| `value`        | `Int`/`Float64`/`missing`   | value in the unit given by `measure` |
| `female`/`male`/`unspecified` | `Int`/`missing` | victims by sex, where reported |
| `rate_100k`    | `Float64`/`missing`         | only with `relative = true`        |

# Examples
```julia
julia> df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso");

julia> df = fetch_vde(state = ["PE", "BA"], year = 2020:2023,
                      category = "drugs", granularity = :year, relative = true);
```

!!! note "Methodological break"
    The VDE series and the classic Sinesp series ([`fetch_sinesp`](@ref)) use
    different collection methodologies and are deliberately **not** merged.
    See the *Data harmonization* page of the documentation.
"""
function fetch_vde(; state = nothing, municipality = nothing, year = nothing,
                   typology = nothing, category = nothing,
                   granularity::Symbol = :month, relative::Bool = false,
                   geometry::Bool = false, refresh::Bool = false,
                   progress::Bool = true)
    years = _validate_years(year, VDE_FIRST_YEAR, Dates.year(Dates.today()), "Sinesp-VDE")
    paths = Dict{Int,String}()
    for y in years
        try
            paths[y] = _ensure_file(_vde_url(y), "vde", "bancovde-$(y).xlsx";
                                    refresh, progress)
        catch err
            # O arquivo do ano corrente pode ainda não existir no início do ano
            if y == Dates.year(Dates.today()) && year === nothing
                @warn "DeBRief: bancovde-$(y).xlsx not available yet; skipping." 
            else
                rethrow(err)
            end
        end
    end
    isempty(paths) && error("DeBRief: no VDE files could be downloaded.")
    return _assemble_vde(paths; state, municipality, year, typology, category,
                         granularity, relative, geometry, progress)
end
