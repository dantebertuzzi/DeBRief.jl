# População via API do SIDRA/IBGE (tabela 6579 — Estimativas de População,
# variável 9324), usada para taxas por 100 mil habitantes e para resolver
# códigos IBGE de municípios (os arquivos do VDE trazem apenas o NOME do
# município, sem código).
#
# A API apisidra.ibge.gov.br responde apenas JSON. Para não adicionar uma
# dependência de JSON ao core, usamos um micro-parser baseado em regex que
# explora o fato de a resposta ser um array plano de objetos SEM aninhamento:
#   [{"NC":"...","V":"1234","D1C":"26","D1N":"Pernambuco",...}, ...]
# O primeiro objeto é o cabeçalho (V == "Valor") e é descartado. Se o IBGE
# mudar o formato, os testes offline contra as fixtures acusam a quebra.

const SIDRA_BASE = "https://apisidra.ibge.gov.br/values/t/6579/"

# nível -> fragmento da URL (n3 = UF, n6 = município)
_sidra_url(level::Symbol, year::Integer) =
    SIDRA_BASE * (level === :state ? "n3" : "n6") * "/all/v/9324/p/$(year)?formato=json"

"""
    _parse_sidra(json) -> Vector{NamedTuple{(:code, :name, :value)}}

Extract `(code = D1C, name = D1N, value = V)` triples from an apisidra JSON
response, skipping the header object. Internal helper, unit-tested offline
against fixtures in `test/data/`.
"""
function _parse_sidra(json::AbstractString)
    out = NamedTuple{(:code, :name, :value),Tuple{String,String,Int}}[]
    # Objetos do apisidra são planos: {"K":"v",...} sem chaves aninhadas
    for m in eachmatch(r"\{[^{}]*\}", json)
        obj = m.match
        v = match(r"\"V\"\s*:\s*\"([^\"]*)\"", obj)
        c = match(r"\"D1C\"\s*:\s*\"([^\"]*)\"", obj)
        n = match(r"\"D1N\"\s*:\s*\"([^\"]*)\"", obj)
        (v === nothing || c === nothing || n === nothing) && continue
        value = tryparse(Int, v.captures[1])
        value === nothing && continue  # descarta o objeto-cabeçalho ("Valor")
        push!(out, (code = c.captures[1], name = n.captures[1], value = value))
    end
    return out
end

# Extrai (nome, UF) de um D1N municipal do SIDRA, ex.: "Petrolina (PE)"
function _split_mun_name(d1n::AbstractString)
    m = match(r"^(.*?)\s*\(([A-Z]{2})\)\s*$", strip(d1n))
    m === nothing && return (strip(d1n), "")
    return (String(m.captures[1]), String(m.captures[2]))
end

"""
    _population(level, year; progress = true) -> Vector{NamedTuple}

Download (or read from cache) the SIDRA population estimates for `level`
(`:state` or `:municipality`) and `year`, with fallback to neighboring years
when the requested one is not published (e.g. the 2022 census year has no
estimate in table 6579). Returns the parsed triples. Internal helper.
"""
function _population(level::Symbol, year::Integer; progress::Bool = true)
    # Fallback: ano pedido, depois vizinhos — o SIDRA não publica estimativa
    # para todos os anos (2022 é Censo) nem para anos ainda não fechados.
    for (i, y) in enumerate((year, year - 1, year + 1, year - 2))
        dest = cache_path("population", "sidra_$(level)_$(y).json")
        json = ""
        if isfile(dest)
            json = read(dest, String)
        else
            try
                _download(_sidra_url(level, y), dest;
                          cfg = DownloadConfig(; progress, min_size = 64))
                json = read(dest, String)
                # Só mantém no cache respostas que realmente têm dados
                if !occursin("\"D1C\"", json)
                    rm(dest; force = true)
                    json = ""
                end
            catch
                json = ""
            end
        end
        rows = isempty(json) ? similar(_parse_sidra("[]"), 0) : _parse_sidra(json)
        if !isempty(rows)
            i > 1 && @warn "DeBRief: SIDRA population for $year unavailable; using $y instead."
            return rows
        end
    end
    error("DeBRief: could not obtain SIDRA population for $level/$year " *
          "(tried $year and neighboring years).")
end

# ---------------------------------------------------------------------------
# Lookups derivados

# Dict "sigla UF" => população (nível estadual; D1N traz o nome por extenso)
function _population_by_uf(year::Integer; progress::Bool = true)
    rows = _population(:state, year; progress)
    return Dict(UF_NAME_TO_ABBREV[normalize_key(r.name)] => r.value
                for r in rows if haskey(UF_NAME_TO_ABBREV, normalize_key(r.name)))
end

# Dict "nome normalizado|UF" => população (nível municipal)
function _population_by_municipality(year::Integer; progress::Bool = true)
    rows = _population(:municipality, year; progress)
    d = Dict{String,Int}()
    for r in rows
        name, uf = _split_mun_name(r.name)
        isempty(uf) && continue
        d[normalize_key(name) * "|" * uf] = r.value
    end
    return d
end

"""
    _municipality_lookup(; progress = true)
        -> (bycode :: Dict{Int,Tuple{String,String}},
            byname :: Dict{String,Int})

Municipality registry derived from the most recent cached SIDRA municipal
response: IBGE code -> (name, UF) and "normalized name|UF" -> code. Used to
accept IBGE codes in the `municipality` filter and to join IBGE meshes in
the geo extension. Internal helper.
"""
function _municipality_lookup(; progress::Bool = true)
    rows = _population(:municipality, Dates.year(Dates.today()) - 1; progress)
    bycode = Dict{Int,Tuple{String,String}}()
    byname = Dict{String,Int}()
    for r in rows
        code = tryparse(Int, r.code)
        code === nothing && continue
        name, uf = _split_mun_name(r.name)
        isempty(uf) && continue
        bycode[code] = (name, uf)
        byname[normalize_key(name) * "|" * uf] = code
    end
    return bycode, byname
end
