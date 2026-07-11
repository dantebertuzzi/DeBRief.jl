# audit.jl — Compara os dados baixados da fonte primária (gov.br) com o
# output normalizado do DeBRief.jl, detectando ruído, divergências ou defeitos.
#
# Uso:
#   julia --project audit.jl
#   julia --project audit.jl 2023          # audita só um ano do VDE
#   julia --project audit.jl 2023 2024     # audita anos específicos do VDE
#   julia --project audit.jl sinesp        # audita só o Sinesp clássico
#   julia --project audit.jl all           # audita tudo (VDE 2015–atual + Sinesp)
#
# Primeira execução baixa os arquivos (~vários MB cada); seguintes usam cache.

const PROJETO = @__DIR__

cd(PROJETO)

using Pkg
Pkg.activate(PROJETO)
Pkg.instantiate()

using DeBRief
using DataFrames, Dates, XLSX, Unicode

# ---------------------------------------------------------------------------
# Utilidades

struct AuditReport
    source::String       # :vde ou :sinesp
    year::Int            # ano do arquivo (0 = único para sinesp)
    n_raw::Int           # linhas no arquivo bruto
    n_normalized::Int    # linhas no output do DeBRief
    matched::Int         # grupos casados
    missing_raw::Int     # grupos no bruto ausentes do DeBRief
    missing_norm::Int    # grupos no DeBRief ausentes do bruto
    value_diffs::Int     # grupos com divergência de valor
    total_diff::Float64  # soma das divergências absolutas
    diffs::Vector{NamedTuple{(:uf, :municipio, :data, :tipologia_bruta, :tipologia_canonica, :valor_bruto, :valor_norm, :diff),Tuple{String,String,Date,String,String,Float64,Float64,Float64}}}
end

# ---------------------------------------------------------------------------
# Sinesp clássico

function resolve_month(raw_month::AbstractString)
    map = Dict(
        "janeiro" => 1, "fevereiro" => 2, "marco" => 3, "abril" => 4,
        "maio" => 5, "junho" => 6, "julho" => 7, "agosto" => 8,
        "setembro" => 9, "outubro" => 10, "novembro" => 11, "dezembro" => 12,
    )
    key = Unicode.normalize(lowercase(strip(string(raw_month))); casefold = true, stripmark = true)
    key = replace(key, r"\s+" => " ")
    return get(map, key, 0)
end

function audit_sinesp()
    println("\n" * "="^70)
    println("AUDITANDO Sinesp Clássico (2015–2022)")
    println("="^70)

    url = DeBRief.SINESP_UF_URL
    path = DeBRief._ensure_file(url, "sinesp", "indicadoressegurancapublicauf.xlsx"; progress = true)

    # Lê o XLSX bruto, SEM passar pela normalização do DeBRief
    xf = XLSX.readxlsx(path)
    sheet = xf[first(XLSX.sheetnames(xf))]
    raw = DataFrame(XLSX.gettable(sheet; infer_eltypes = true))

    println("  Raw columns: ", join(names(raw), ", "))
    println("  Raw rows: $(nrow(raw))")

    # Extrai colunas do bruto
    bruto_uf = [DeBRief._resolve_uf(raw.UF[i]) for i in 1:nrow(raw)]
    bruto_data = [Date(raw.Ano[i], resolve_month(raw.Mês[i]), 1) for i in 1:nrow(raw)]
    bruto_tipo = [string(raw."Tipo Crime"[i]) for i in 1:nrow(raw)]
    bruto_valor = [Int(raw.Ocorrências[i]) for i in 1:nrow(raw)]

    # Cria DataFrame intermediário do bruto
    df_bruto = DataFrame(; state = bruto_uf, date = bruto_data,
                         raw_typology = bruto_tipo, raw_value = bruto_valor)

    # Tenta mapear as tipologias brutas para canônicas
    canonical = String[]
    for t in bruto_tipo
        try
            push!(canonical, DeBRief.match_typology(t, :sinesp))
        catch
            push!(canonical, "UNKNOWN: $t")
        end
    end
    df_bruto[!, :typology] = canonical

    # Agrupa o bruto por (state, date, raw_typology, typology) e soma
    gd_bruto = groupby(df_bruto, [:state, :date, :raw_typology, :typology])
    bruto_sum = combine(gd_bruto, :raw_value => sum => :raw_value)

    # Obtém o output do DeBRief (normalizado, filtrado para o conjunto completo)
    df_norm = DeBRief._parse_sinesp(path)

    # Agrupa o normalizado por (state, date, typology)
    gd_norm = groupby(df_norm, [:state, :date, :typology])
    norm_sum = combine(gd_norm, :value => sum => :norm_value)

    # Compara os datasets
    n_raw = nrow(bruto_sum)
    n_norm = nrow(norm_sum)
    diffs = []
    matched = 0
    missing_raw = 0
    missing_norm = 0
    value_diffs = 0
    total_diff = 0.0

    n_key = nrow(norm_sum)
    b_key = nrow(bruto_sum)

    # Cria conjuntos de chaves para cada
    # Para o bruto, cada tipologia bruta mapeia para uma canônica; grupo bruto é (uf, data, tipologia bruta)
    # Para o normalizado, grupo é (uf, data, tipologia canônica)
    
    # Mapa: (uf, date, canonical_typology) -> soma de raw_values (várias raw podem mapear p/ mesma canônica)
    bruto_key_map = Dict{Tuple{String,Date,String},Float64}()
    for row in eachrow(bruto_sum)
        key = (row.state, row.date, row.typology)
        bruto_key_map[key] = get(bruto_key_map, key, 0.0) + row.raw_value
    end

    norm_key_map = Dict{Tuple{String,Date,String},Float64}()
    for row in eachrow(norm_sum)
        key = (row.state, row.date, row.typology)
        norm_key_map[key] = row.norm_value
    end

    n_raw = length(bruto_key_map)
    n_norm = length(norm_key_map)

    all_keys = union(keys(bruto_key_map), keys(norm_key_map))
    for key in sort(collect(all_keys))
        raw_v = get(bruto_key_map, key, nothing)
        norm_v = get(norm_key_map, key, nothing)

        if raw_v === nothing
            missing_raw += 1
            push!(diffs, (uf = key[1], municipio = "", data = key[2],
                          tipologia_bruta = "", tipologia_canonica = key[3],
                          valor_bruto = 0.0, valor_norm = norm_v, diff = -norm_v))
        elseif norm_v === nothing
            missing_norm += 1
            push!(diffs, (uf = key[1], municipio = "", data = key[2],
                          tipologia_bruta = "", tipologia_canonica = key[3],
                          valor_bruto = raw_v, valor_norm = 0.0, diff = raw_v))
        else
            matched += 1
            diff = abs(raw_v - norm_v)
            total_diff += diff
            if diff > 0.01
                value_diffs += 1
                push!(diffs, (uf = key[1], municipio = "", data = key[2],
                              tipologia_bruta = "", tipologia_canonica = key[3],
                              valor_bruto = raw_v, valor_norm = norm_v, diff = diff))
            end
        end
    end

    report = AuditReport("sinesp", 0, n_raw, n_norm, matched, missing_raw, missing_norm,
                         value_diffs, total_diff, diffs)
    print_report(report)
    return report
end

# ---------------------------------------------------------------------------
# VDE

function audit_vde(years::Vector{Int})
    println("\n" * "="^70)
    println("AUDITANDO Sinesp-VDE — anos: $(join(sort(years), ", "))")
    println("="^70)

    reports = AuditReport[]
    for year in sort(years)
        println("\n─── Ano $year " * "─"^50)
        url = DeBRief._vde_url(year)
        local path
        try
            path = DeBRief._ensure_file(url, "vde", "bancovde-$(year).xlsx"; progress = true)
        catch err
            println("  [SKIP] Não foi possível baixar bancovde-$year.xlsx: $err")
            continue
        end

        # Lê o XLSX bruto (sem normalização do DeBRief)
        xf = XLSX.readxlsx(path)
        sheet = xf[first(XLSX.sheetnames(xf))]
        raw = DataFrame(XLSX.gettable(sheet))

        # Normaliza nomes de colunas
        rename!(raw, [n => DeBRief._norm_header(n) for n in names(raw)])

        # Garante colunas necessárias
        for c in (:feminino, :masculino, :nao_informado, :total, :total_peso, :total_vitima)
            hasproperty(raw, c) || (raw[!, c] = fill(missing, nrow(raw)))
        end

        # Mapeia tipologia bruta para canônica (usando a mesma lógica do DeBRief)
        canonical = String[]
        unknown = Set{String}()
        for i in 1:nrow(raw)
            eraw = string(raw.evento[i])
            typ = DeBRief._canonical_typology(eraw, year)
            if typ === nothing
                push!(canonical, String(strip(eraw)))
                push!(unknown, eraw)
            else
                push!(canonical, typ.name)
            end
        end
        if !isempty(unknown)
            unknown_names = unique(sort(collect(unknown)))
            println("  ⚠  Tipologias sem mapeamento canônico: $(join(unknown_names, ", "))")
        end

        # Constrói o DataFrame bruto com as mesmas chaves
        bruto_uf = String[]
        bruto_mun = String[]
        bruto_data = Date[]
        bruto_tipo_raw = String[]
        bruto_tipo_canon = String[]
        bruto_valor = Float64[]

        for i in 1:nrow(raw)
            dt = try
                DeBRief._refmonth(raw.data_referencia[i])
            catch
                continue  # pula linhas com data inválida
            end
            push!(bruto_uf, DeBRief._resolve_uf(string(raw.uf[i])))
            push!(bruto_mun, strip(string(raw.municipio[i])))
            push!(bruto_data, dt)
            push!(bruto_tipo_raw, string(raw.evento[i]))
            push!(bruto_tipo_canon, canonical[i])

            # Determina a unidade de medida e extrai o valor da coluna correta
            typ = DeBRief._canonical_typology(string(raw.evento[i]), year)
            if typ === nothing
                measure = !ismissing(raw.total_vitima[i]) ? :victims :
                          !ismissing(raw.total_peso[i])   ? :kg : :occurrences
            else
                measure = typ.measure
            end
            vcol = DeBRief._value_column(measure)

            if measure === :kg
                val = !ismissing(raw[i, vcol]) ? Float64(raw[i, vcol]) : missing
            elseif measure in (:victims, :people)
                alt = vcol === :total_vitima ? :total : :total_vitima
                sexsum = DeBRief._sumskip([DeBRief._int(raw.feminino[i]),
                                           DeBRief._int(raw.masculino[i]),
                                           DeBRief._int(raw.nao_informado[i])])
                val = DeBRief._first_count(DeBRief._int(raw[i, vcol]),
                                           DeBRief._int(raw[i, alt]),
                                           sexsum)
            else
                val = DeBRief._int(raw[i, vcol])
            end
            push!(bruto_valor, ismissing(val) ? 0.0 : Float64(val))
        end

        df_bruto = DataFrame(; state = bruto_uf, municipality = bruto_mun,
                             date = bruto_data, raw_typology = bruto_tipo_raw,
                             typology = bruto_tipo_canon, value = bruto_valor)

        # Agrupa o bruto por (state, municipality, date, typology) — mesma
        # chave de agregação que o _parse_vde usa
        gd_bruto = groupby(df_bruto, [:state, :municipality, :date, :typology])
        bruto_sum = combine(gd_bruto, :value => sum => :value)

        # Obtém o output normalizado do DeBRief
        df_norm = DeBRief._parse_vde(path, year)

        # Compara
        bruto_key_map = Dict{Tuple{String,String,Date,String},Float64}()
        for row in eachrow(bruto_sum)
            key = (row.state, row.municipality, row.date, row.typology)
            bruto_key_map[key] = get(bruto_key_map, key, 0.0) + row.value
        end

        norm_key_map = Dict{Tuple{String,String,Date,String},Float64}()
        for row in eachrow(df_norm)
            key = (row.state, row.municipality, row.date, row.typology)
            # Soma caso haja duplicatas no normalizado (não deveria, mas por segurança)
            norm_key_map[key] = Float64(ismissing(row.value) ? 0.0 : row.value)
        end

        n_raw = length(bruto_key_map)
        n_norm = length(norm_key_map)
        matched = 0
        missing_raw = 0
        missing_norm = 0
        value_diffs = 0
        total_diff = 0.0
        diffs = []

        all_keys = union(keys(bruto_key_map), keys(norm_key_map))
        for key in sort(collect(all_keys))
            raw_v = get(bruto_key_map, key, nothing)
            norm_v = get(norm_key_map, key, nothing)

            if raw_v === nothing
                missing_raw += 1
                push!(diffs, (uf = key[1], municipio = key[2], data = key[3],
                              tipologia_bruta = "", tipologia_canonica = key[4],
                              valor_bruto = 0.0, valor_norm = norm_v, diff = -norm_v))
            elseif norm_v === nothing
                missing_norm += 1
                push!(diffs, (uf = key[1], municipio = key[2], data = key[3],
                              tipologia_bruta = "", tipologia_canonica = key[4],
                              valor_bruto = raw_v, valor_norm = 0.0, diff = raw_v))
            else
                matched += 1
                diff = abs(raw_v - norm_v)
                total_diff += diff
                if diff > 0.01
                    value_diffs += 1
                    push!(diffs, (uf = key[1], municipio = key[2], data = key[3],
                                  tipologia_bruta = "", tipologia_canonica = key[4],
                                  valor_bruto = raw_v, valor_norm = norm_v, diff = diff))
                end
            end
        end

        report = AuditReport("vde", year, n_raw, n_norm, matched, missing_raw, missing_norm,
                             value_diffs, total_diff, diffs)
        print_report(report)
        push!(reports, report)
    end
    return reports
end

# ---------------------------------------------------------------------------
# Impressão do relatório

function print_report(r::AuditReport)
    total_items = r.matched + r.missing_raw + r.missing_norm
    pct_matched = total_items > 0 ? r.matched / total_items * 100 : 0.0
    
    println("  Grupos no bruto:       $(r.n_raw)")
    println("  Grupos no normalizado: $(r.n_normalized)")
    println("  Casados:               $(r.matched) ($(round(pct_matched, digits = 1))%)")
    println("  Ausentes do DeBRief:   $(r.missing_raw)")
    println("  Ausentes do bruto:     $(r.missing_norm)")
    println("  Divergências de valor: $(r.value_diffs)")
    println("  Soma |diff|:           $(round(r.total_diff, digits = 2))")

    if r.value_diffs > 0
        println("\n  ─── Divergências de valor (até 20) ───")
        shown = 0
        # Ordena por diff decrescente
        sorted = sort(r.diffs; by = d -> -d.diff)
        for d in sorted
            shown += 1
            shown > 20 && break
            prefix = d.municipio == "" ? "$(d.uf)" : "$(d.uf)/$(d.municipio)"
            println("  $(prefix) | $(d.data) | $(d.tipologia_canonica)")
            println("    bruto: $(d.valor_bruto)  norm: $(d.valor_norm)  diff: $(d.diff)")
        end
        if shown < length(r.diffs)
            println("  ... mais $(length(r.diffs) - shown) divergências omitidas")
        end
    end

    if r.missing_raw > 0
        println("\n  ─── Grupos ausentes do DeBRief (até 10) ───")
        shown = 0
        for d in r.diffs
            d.valor_norm > 0 || continue  # só os que têm valor no norm mas não no bruto
            shown += 1
            shown > 10 && break
            prefix = d.municipio == "" ? "$(d.uf)" : "$(d.uf)/$(d.municipio)"
            println("  $(prefix) | $(d.data) | $(d.tipologia_canonica) = $(d.valor_norm)")
        end
    end

    if r.missing_norm > 0
        println("\n  ─── Grupos ausentes do arquivo bruto (até 10) ───")
        shown = 0
        for d in r.diffs
            d.valor_bruto > 0 || continue
            shown += 1
            shown > 10 && break
            prefix = d.municipio == "" ? "$(d.uf)" : "$(d.uf)/$(d.municipio)"
            println("  $(prefix) | $(d.data) | $(d.tipologia_canonica) = $(d.valor_bruto)")
        end
    end
end

# ---------------------------------------------------------------------------
# Main

const CURRENT_YEAR = Dates.year(Dates.today())

function main()
    args = ARGS

    if isempty(args)
        args = ["all"]
    end

    if "all" in args
        println("╔" * "═"^68 * "╗")
        println("║  DeBRief.jl — Auditoria de Integridade dos Dados                 ║")
        println("║  Compara arquivos brutos da fonte primária (gov.br) com o        ║")
        println("║  output normalizado do pacote.                                   ║")
        println("╚" * "═"^68 * "╝")

        audit_sinesp()
        audit_vde(collect(DeBRief.VDE_FIRST_YEAR:min(CURRENT_YEAR, 2025)))
    elseif "sinesp" in args
        audit_sinesp()
    else
        years = Int[]
        for a in args
            y = tryparse(Int, a)
            y === nothing && error("Argumento inválido: '$a'. Use anos (ex: 2023), 'sinesp' ou 'all'.")
            push!(years, y)
        end
        audit_vde(years)
    end
end

main()
