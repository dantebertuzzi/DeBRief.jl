# Camada de normalização — o núcleo do valor do pacote.
#
# Os arquivos do Sinesp mudam de layout, nomenclatura de tipologias e
# metodologia entre anos. Esta camada concentra:
#   1. normalização de texto (caixa/acentos) para matching tolerante;
#   2. a tabela de UFs (sigla, nome, código IBGE);
#   3. os dicionários de-para de tipologias, versionados por ano;
#   4. o vocabulário canônico com categoria e unidade de medida por indicador.
#
# As decisões de harmonização estão documentadas em docs/src/harmonization.md.

# ---------------------------------------------------------------------------
# Normalização de texto

"""
    normalize_key(s) -> String

Lowercase, accent-stripped, whitespace-collapsed version of `s`, used for
tolerant matching of typologies, states and municipalities
(`"Homicídio Doloso" -> "homicidio doloso"`). Internal helper.
"""
function normalize_key(s)
    t = Unicode.normalize(String(strip(string(s))); casefold = true, stripmark = true)
    return replace(t, r"\s+" => " ")
end

# Normaliza um header de coluna do XLSX para Symbol ("Tipo Crime" -> :tipo_crime)
_norm_header(s) = Symbol(replace(normalize_key(s), r"[\s/-]+" => "_"))

# ---------------------------------------------------------------------------
# Unidades da Federação

# (sigla, nome, código IBGE) — usado para converter o nome por extenso do
# Sinesp clássico em sigla e para o join com as malhas do IBGE na extensão geo.
const UF_TABLE = [
    ("AC", "Acre", 12),                ("AL", "Alagoas", 27),
    ("AP", "Amapá", 16),               ("AM", "Amazonas", 13),
    ("BA", "Bahia", 29),               ("CE", "Ceará", 23),
    ("DF", "Distrito Federal", 53),    ("ES", "Espírito Santo", 32),
    ("GO", "Goiás", 52),               ("MA", "Maranhão", 21),
    ("MT", "Mato Grosso", 51),         ("MS", "Mato Grosso do Sul", 50),
    ("MG", "Minas Gerais", 31),        ("PA", "Pará", 15),
    ("PB", "Paraíba", 25),             ("PR", "Paraná", 41),
    ("PE", "Pernambuco", 26),          ("PI", "Piauí", 22),
    ("RJ", "Rio de Janeiro", 33),      ("RN", "Rio Grande do Norte", 24),
    ("RS", "Rio Grande do Sul", 43),   ("RO", "Rondônia", 11),
    ("RR", "Roraima", 14),             ("SC", "Santa Catarina", 42),
    ("SP", "São Paulo", 35),           ("SE", "Sergipe", 28),
    ("TO", "Tocantins", 17),
]

const UF_ABBREVS = Set(first.(UF_TABLE))
# nome normalizado -> sigla ("pernambuco" => "PE")
const UF_NAME_TO_ABBREV = Dict(normalize_key(n) => a for (a, n, _) in UF_TABLE)
# sigla -> código IBGE ("PE" => 26)
const UF_ABBREV_TO_CODE = Dict(a => c for (a, _, c) in UF_TABLE)

"""
    _resolve_uf(x) -> String

Resolve a user-provided state (abbreviation or full name, any casing or
accents) into the canonical two-letter abbreviation. Throws an informative
`ArgumentError` when no match exists. Internal helper.
"""
function _resolve_uf(x)
    key = normalize_key(x)
    up = uppercase(strip(string(x)))
    up in UF_ABBREVS && return up
    haskey(UF_NAME_TO_ABBREV, key) && return UF_NAME_TO_ABBREV[key]
    throw(ArgumentError(
        "Unknown state $(repr(string(x))). Valid abbreviations: " *
        join(sort(collect(UF_ABBREVS)), ", ")))
end

# Meses por extenso do arquivo do Sinesp clássico ("janeiro" -> 1)
const MONTH_NAMES = Dict(
    "janeiro" => 1, "fevereiro" => 2, "marco" => 3, "abril" => 4,
    "maio" => 5, "junho" => 6, "julho" => 7, "agosto" => 8,
    "setembro" => 9, "outubro" => 10, "novembro" => 11, "dezembro" => 12,
)

# ---------------------------------------------------------------------------
# Vocabulário canônico do Sinesp-VDE
#
# Cada indicador tem uma categoria (agrupamento analítico) e uma unidade de
# medida. A unidade determina de qual coluna da fonte o valor é lido:
#   :victims     -> total_vitima  (vítimas em BOs)
#   :occurrences -> total         (registros de ocorrência)
#   :kg          -> total_peso    (apreensões de drogas, em quilos)
#   :units       -> total         (armas de fogo apreendidas)
#   :people      -> total         (desaparecidos/localizados)
#   :warrants    -> total         (mandados cumpridos)
#   :services    -> total         (atendimentos de bombeiros)

struct Typology
    name::String       # nome canônico (como difundido pelo MJSP)
    category::String
    measure::Symbol
end

const VDE_TYPOLOGIES = [
    Typology("Homicídio doloso", "victims", :victims),
    Typology("Feminicídio", "victims", :victims),
    Typology("Tentativa de homicídio", "victims", :victims),
    Typology("Tentativa de feminicídio", "victims", :victims),
    Typology("Lesão corporal seguida de morte", "victims", :victims),
    Typology("Roubo seguido de morte (latrocínio)", "victims", :victims),
    Typology("Morte por intervenção de Agente do Estado", "victims", :victims),
    Typology("Mortes a esclarecer (sem indício de crime)", "victims", :victims),
    Typology("Morte no trânsito ou em decorrência dele (exceto homicídio doloso)", "victims", :victims),
    Typology("Suicídio", "victims", :victims),
    Typology("Estupro", "victims", :victims),
    Typology("Morte de Agente do Estado", "state_agents", :victims),
    Typology("Suicídio de Agente do Estado", "state_agents", :victims),
    Typology("Roubo de veículo", "occurrences", :occurrences),
    Typology("Furto de veículo", "occurrences", :occurrences),
    Typology("Roubo de carga", "occurrences", :occurrences),
    Typology("Roubo a instituição financeira", "occurrences", :occurrences),
    Typology("Tráfico de drogas", "drugs", :occurrences),
    Typology("Apreensão de Cocaína", "drugs", :kg),
    Typology("Apreensão de Maconha", "drugs", :kg),
    Typology("Arma de Fogo Apreendida", "firearms", :units),
    Typology("Pessoa Desaparecida", "missing_persons", :people),
    Typology("Pessoa Localizada", "missing_persons", :people),
    Typology("Mandado de prisão cumprido", "warrants", :warrants),
    Typology("Atendimento pré-hospitalar", "fire_dept", :services),
    Typology("Busca e salvamento", "fire_dept", :services),
    Typology("Combate a incêndios", "fire_dept", :services),
    Typology("Emissão de Alvarás de licença", "fire_dept", :services),
    Typology("Realização de vistorias", "fire_dept", :services),
]

const VDE_BY_KEY = Dict(normalize_key(t.name) => t for t in VDE_TYPOLOGIES)
const VDE_CATEGORIES = sort(unique(t.category for t in VDE_TYPOLOGIES))

# ---------------------------------------------------------------------------
# Dicionários de-para de tipologias (VDE), versionados por ano
#
# O vocabulário da coluna `evento` deriva entre publicações. Exemplos
# documentados:
#   * a Portaria 229/2018 fala em "Apreensão de arma de fogo" e "Homicídio na
#     forma tentada"; os arquivos usam "Arma de Fogo Apreendida" e
#     "Tentativa de homicídio";
#   * "Tentativa de feminicídio" só aparece nos arquivos mais recentes;
#   * variações de plural ("Roubo de veículos" vs "Roubo de veículo") e de
#     pontuação ocorrem entre anos.
#
# `VDE_ALIASES` cobre as variações independentes de ano; `VDE_ALIASES_BY_YEAR`
# permite sobrepor casos específicos de um ano (chave = ano do arquivo).
# Para estender: adicionar `normalize_key(variante) => nome canônico`.

const VDE_ALIASES = Dict{String,String}(
    # Variações normativas x arquivo
    "homicidio na forma tentada" => "Tentativa de homicídio",
    "apreensao de arma de fogo" => "Arma de Fogo Apreendida",
    "morte a esclarecer (sem indicio de crime)" => "Mortes a esclarecer (sem indício de crime)",
    "morte a esclarecer" => "Mortes a esclarecer (sem indício de crime)",
    "morte no transito ou em decorrencia dele" => "Morte no trânsito ou em decorrência dele (exceto homicídio doloso)",
    "mortes no transito" => "Morte no trânsito ou em decorrência dele (exceto homicídio doloso)",
    "roubo seguido de morte" => "Roubo seguido de morte (latrocínio)",
    "latrocinio" => "Roubo seguido de morte (latrocínio)",
    "morte por intervencao de agente do estado" => "Morte por intervenção de Agente do Estado",
    # Singular/plural
    "roubo de veiculos" => "Roubo de veículo",
    "furto de veiculos" => "Furto de veículo",
    "emissao de alvara de licenca" => "Emissão de Alvarás de licença",
    "emissao de alvaras de licenca" => "Emissão de Alvarás de licença",
)

const VDE_ALIASES_BY_YEAR = Dict{Int,Dict{String,String}}(
    # Sem sobreposições específicas conhecidas até o momento; a estrutura fica
    # pronta para receber quebras futuras sem alterar o pipeline.
)

"""
    _canonical_typology(raw, year) -> Union{Typology,Nothing}

Map a raw `evento` string from a VDE file of a given `year` to the canonical
[`Typology`](@ref), or `nothing` when the value is not recognized (forward
compatibility: unknown indicators are kept with category `"other"`).
Internal helper.
"""
function _canonical_typology(raw, year::Integer)
    key = normalize_key(raw)
    # 1. Sobreposição específica do ano tem precedência
    yearly = get(VDE_ALIASES_BY_YEAR, Int(year), nothing)
    if yearly !== nothing && haskey(yearly, key)
        return VDE_BY_KEY[normalize_key(yearly[key])]
    end
    # 2. Alias global
    haskey(VDE_ALIASES, key) && return VDE_BY_KEY[normalize_key(VDE_ALIASES[key])]
    # 3. Nome canônico direto
    return get(VDE_BY_KEY, key, nothing)
end

# ---------------------------------------------------------------------------
# Sinesp clássico — as nove tipologias da série histórica por UF (2015–2022)

const SINESP_TYPOLOGIES = [
    "Estupro",
    "Furto de veículo",
    "Homicídio doloso",
    "Lesão corporal seguida de morte",
    "Roubo a instituição financeira",
    "Roubo de carga",
    "Roubo de veículo",
    "Roubo seguido de morte (latrocínio)",
    "Tentativa de homicídio",
]

const SINESP_ALIASES = Dict{String,String}(
    "roubo seguido de morte" => "Roubo seguido de morte (latrocínio)",
    "latrocinio" => "Roubo seguido de morte (latrocínio)",
)

const SINESP_BY_KEY = Dict(normalize_key(t) => t for t in SINESP_TYPOLOGIES)

# ---------------------------------------------------------------------------
# Matching tolerante exposto ao usuário

"""
    match_typology(x, source::Symbol) -> String

Resolve a user-provided typology into its canonical name, ignoring case and
accents (`"homicidio doloso" == "Homicídio Doloso"`). `source` is `:vde` or
`:sinesp`. Throws an `ArgumentError` listing the valid options when there is
no match. Internal helper (the public entry points are the `typology`
keyword arguments and [`typologies`](@ref)).
"""
function match_typology(x, source::Symbol)
    key = normalize_key(x)
    if source === :vde
        haskey(VDE_ALIASES, key) && return VDE_BY_KEY[normalize_key(VDE_ALIASES[key])].name
        haskey(VDE_BY_KEY, key) && return VDE_BY_KEY[key].name
        throw(ArgumentError(
            "Unknown VDE typology $(repr(string(x))). Valid options:\n  " *
            join(typologies(:vde), "\n  ")))
    elseif source === :sinesp
        haskey(SINESP_ALIASES, key) && return SINESP_ALIASES[key]
        haskey(SINESP_BY_KEY, key) && return SINESP_BY_KEY[key]
        throw(ArgumentError(
            "Unknown classic Sinesp typology $(repr(string(x))). Valid options:\n  " *
            join(typologies(:sinesp), "\n  ")))
    else
        throw(ArgumentError("Unknown source $(repr(source)); use :vde or :sinesp."))
    end
end

"""
    typologies(source::Symbol = :vde) -> Vector{String}

List the canonical typology names available in a data source (`:vde` or
`:sinesp`).

# Examples
```julia
julia> typologies(:sinesp)
9-element Vector{String}:
 "Estupro"
 ⋮
 "Tentativa de homicídio"

julia> "Homicídio doloso" in typologies(:vde)
true
```
"""
function typologies(source::Symbol = :vde)
    source === :vde && return sort([t.name for t in VDE_TYPOLOGIES])
    source === :sinesp && return copy(SINESP_TYPOLOGIES)
    throw(ArgumentError("Unknown source $(repr(source)); use :vde or :sinesp."))
end

# ---------------------------------------------------------------------------
# Coerções de tipos vindos do XLSX

# Soma ignorando missing; devolve missing quando não há nenhum valor
_sumskip(v) = all(ismissing, v) ? missing : sum(skipmissing(v))

# Reestreita o tipo de :value após agregações: sum() sobre a coluna com
# eltype Union{Int,Float64} promove tudo para Float64, mas cada grupo é
# homogêneo em `measure` — contagens voltam a Int, pesos (:kg) ficam Float64.
function _narrow_value!(df)
    df[!, :value] = Union{Missing,Int,Float64}[
        ismissing(v) ? missing : (m === :kg ? Float64(v) : Int(round(v)))
        for (v, m) in zip(df.value, df.measure)]
    return df
end

# Primeira contagem não-missing e não-zero de uma cadeia de candidatos;
# se todas forem zero/missing, devolve a primeira não-missing (zero legítimo).
# Usado onde a fonte oscila entre colunas para reportar o mesmo número.
function _first_count(xs...)
    for x in xs
        !ismissing(x) && x != 0 && return x
    end
    for x in xs
        !ismissing(x) && return x
    end
    return missing
end

# Coerção robusta para Int (contagens)
_int(::Missing) = missing
_int(x::Integer) = Int(x)
_int(x::Real) = Int(round(x))
_int(x::AbstractString) = something(tryparse(Int, strip(x)),
                                     tryparse(Float64, strip(x)) === nothing ? missing :
                                     Int(round(tryparse(Float64, strip(x)))))
_int(x) = missing

# Coerção robusta para Float64 (pesos em kg; fonte pode usar vírgula decimal)
_float(::Missing) = missing
_float(x::Real) = Float64(x)
function _float(x::AbstractString)
    s = replace(strip(x), "," => ".")
    v = tryparse(Float64, s)
    return v === nothing ? missing : v
end
_float(x) = missing

# data_referencia chega como Date, DateTime, serial do Excel ou string,
# dependendo de como o arquivo do ano foi gerado. Sempre devolve o primeiro
# dia do mês de referência.
_refmonth(x::Date) = Date(year(x), month(x), 1)
_refmonth(x::DateTime) = _refmonth(Date(x))
_refmonth(x::Real) = _refmonth(Date(1899, 12, 30) + Day(round(Int, x)))  # época do Excel
function _refmonth(x::AbstractString)
    s = strip(x)
    for fmt in (dateformat"y-m-d", dateformat"d/m/y", dateformat"y-m-dTH:M:S")
        d = tryparse(Date, s, fmt)
        d !== nothing && return _refmonth(d)
    end
    error("DeBRief: could not parse reference date $(repr(x)).")
end
_refmonth(::Missing) =
    error("DeBRief: a row has a missing reference date (data_referencia); " *
          "the source file may be corrupted — try `refresh = true`.")
