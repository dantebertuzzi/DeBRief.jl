# Suíte de testes do DeBRief.jl.
#
# Tudo roda OFFLINE contra fixtures pequenas em test/data/ (recortes fiéis ao
# layout real das fontes). Testes que batem na rede de verdade são pulados por
# padrão — habilite com ENV["DEBRIEF_ONLINE_TESTS"] = "true".

using DeBRief
using DataFrames
using Dates
using Random
using Test

using Aqua

const FIX = joinpath(@__DIR__, "data")
const VDE_FIXTURE = Dict(2023 => joinpath(FIX, "bancovde_fixture.xlsx"))
const SINESP_FIXTURE = joinpath(FIX, "sinesp_uf_fixture.xlsx")

@testset "DeBRief.jl" begin

    @testset "Aqua quality checks" begin
        Aqua.test_all(DeBRief)
    end

    @testset "text normalization and matching" begin
        @test DeBRief.normalize_key("Homicídio Doloso") == "homicidio doloso"
        @test DeBRief.normalize_key("  LESÃO  corporal ") == "lesao corporal"
        @test DeBRief.match_typology("homicidio doloso", :vde) == "Homicídio doloso"
        @test DeBRief.match_typology("HOMICÍDIO DOLOSO", :sinesp) == "Homicídio doloso"
        @test DeBRief.match_typology("latrocinio", :vde) ==
              "Roubo seguido de morte (latrocínio)"
        @test DeBRief.match_typology("apreensao de arma de fogo", :vde) ==
              "Arma de Fogo Apreendida"
        @test DeBRief.match_typology("Roubo de veículo automotor", :vde) ==
              "Roubo de veículo"
        @test DeBRief.match_typology("estupro de vulneravel", :vde) ==
              "Estupro de vulnerável"
        @test DeBRief.match_typology("MORTES NO TRÂNSITO", :vde) ==
              "Mortes no trânsito"
        err = try DeBRief.match_typology("crime inexistente", :vde); nothing
              catch e; e end
        @test err isa ArgumentError
        @test occursin("Homicídio doloso", err.msg)  # erro lista as opções válidas

        @test DeBRief._resolve_uf("pe") == "PE"
        @test DeBRief._resolve_uf("Pernambuco") == "PE"
        @test DeBRief._resolve_uf("são paulo") == "SP"
        @test_throws ArgumentError DeBRief._resolve_uf("XX")

        @test length(typologies(:vde)) == length(DeBRief.VDE_TYPOLOGIES)
        @test length(typologies(:sinesp)) == 9
        @test_throws ArgumentError typologies(:nope)
    end

    @testset "cache utilities" begin
        # Não chamamos clear_cache() aqui de propósito: rodar os testes não
        # pode apagar downloads reais do usuário. Só validamos o schema.
        info = cache_info()
        @test info isa DataFrame
        @test names(info) == ["file", "mb"]
        @test all(>=(0), info.mb)
    end

    @testset "type coercions" begin
        @test DeBRief._int("42") == 42
        @test DeBRief._int(41.6) == 42
        @test ismissing(DeBRief._int("abc"))
        @test DeBRief._float("11,15") == 11.15
        @test DeBRief._refmonth(Date(2023, 7, 15)) == Date(2023, 7, 1)
        @test DeBRief._refmonth(45108) == Date(2023, 7, 1)      # serial do Excel
        @test DeBRief._refmonth("2023-07-01") == Date(2023, 7, 1)
        @test DeBRief._refmonth("15/07/2023") == Date(2023, 7, 1)
        @test ismissing(DeBRief._sumskip([missing, missing]))
        @test DeBRief._sumskip([1, missing, 2]) == 3
    end

    @testset "VDE parsing (fixture)" begin
        df = DeBRief._parse_vde(VDE_FIXTURE[2023], 2023)
        @test df isa DataFrame
        @test eltype(df.date) == Date
        @test all(in(("PE", "BA", "SP")), df.state)

        # Linhas duplicadas de Estupro (nota do MJSP) foram somadas
        est = subset(df, :typology => ByRow(==("Estupro")),
                         :date => ByRow(==(Date(2023, 1, 1))))
        @test nrow(est) == 1
        @test est.value[1] == 28          # 22 + 6
        @test est.female[1] == 25         # 20 + 5

        # Unidades de medida corretas por indicador
        hom = subset(df, :typology => ByRow(==("Homicídio doloso")))
        @test all(==( :victims), hom.measure)
        coca = subset(df, :typology => ByRow(==("Apreensão de Cocaína")))
        @test all(==(:kg), coca.measure)
        @test coca.value[1] isa Float64   # inclusive vírgula decimal como string
        rvel = subset(df, :typology => ByRow(==("Roubo de veículo")))
        @test all(==(:occurrences), rvel.measure)
        @test all(v -> v isa Int, skipmissing(rvel.value))

        # Serial do Excel em data_referencia
        furto = subset(df, :typology => ByRow(==("Furto de veículo")))
        @test furto.date[1] == Date(2023, 7, 1)

        # Variante "automotor" do arquivo é normalizada para o canônico
        fsa = subset(df, :municipality => ByRow(==("Feira de Santana")))
        @test nrow(fsa) == 1 && fsa.typology[1] == "Roubo de veículo"
        @test fsa.measure[1] === :occurrences && fsa.value[1] == 58

        # Indicadores novos (2023+) saem canônicos, não como "other"
        vul = subset(df, :typology => ByRow(==("Estupro de vulnerável")))
        @test nrow(vul) == 1 && vul.category[1] == "victims"

        # Linhas de agregado estadual (municipio "NÃO INFORMADO") são mantidas
        ni = subset(df, :municipality => ByRow(==("NÃO INFORMADO")))
        @test nrow(ni) == 2 && all(==("Roubo de carga"), ni.typology)

        # Indicador desconhecido é preservado com categoria "other"
        novo = subset(df, :typology => ByRow(==("Indicador Novo Hipotético")))
        @test nrow(novo) == 1 && novo.category[1] == "other" && novo.value[1] == 42

        # Desagregações (arma) são agregadas no schema municipal-mês-tipologia
        arma = subset(df, :typology => ByRow(==("Arma de Fogo Apreendida")))
        @test nrow(arma) == 1 && arma.value[1] == 23

        # Caso real (arquivos de 2025): desaparecidos/localizados vêm com
        # `total` zerado ou vazio e contagem apenas por sexo — a cadeia de
        # fallback reconstrói o valor a partir das colunas de sexo
        desap = subset(df, :typology => ByRow(==("Pessoa Desaparecida")),
                           :municipality => ByRow(==("Campinas")))
        @test nrow(desap) == 3 && all(==(13), desap.value)   # 5 + 7 + 1
        loc = subset(df, :typology => ByRow(==("Pessoa Localizada")))
        @test loc.value[1] == 5                              # 2 + 3, total missing
        # E zero legítimo continua zero quando tudo é zero
        @test DeBRief._first_count(0, 0, 0) == 0
        @test ismissing(DeBRief._first_count(missing, missing))
        @test DeBRief._first_count(0, missing, 13) == 13
    end

    @testset "parsed-year disk cache" begin
        df1 = DeBRief._parse_vde_cached(VDE_FIXTURE[2023], 2023; progress = false)
        key = "bancovde-2023-v$(DeBRief.PARSER_VERSION)-" *
              "$(filesize(VDE_FIXTURE[2023])).jls"
        @test isfile(DeBRief.cache_path("vde_parsed", key))
        # Segunda chamada vem do cache serializado e deve ser idêntica
        df2 = DeBRief._parse_vde_cached(VDE_FIXTURE[2023], 2023; progress = false)
        @test isequal(df1, df2)
        @test isequal(df1, DeBRief._parse_vde(VDE_FIXTURE[2023], 2023))
    end

    @testset "VDE assembly, filters and granularity (fixture)" begin
        df = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE", year = 2023,
                                   typology = "homicídio doloso", progress = false)
        @test nrow(df) == 24                       # Recife + Petrolina × 12 meses
        @test all(==("PE"), df.state)
        @test sum(df.value) == sum([55,48,60,52,49,58,61,50,47,53,56,59]) +
                               sum([8,6,9,7,5,10,8,6,7,9,8,11])

        anual = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE",
                                      typology = "Homicídio doloso",
                                      granularity = :year, progress = false)
        @test hasproperty(anual, :year) && !hasproperty(anual, :date)
        @test nrow(anual) == 2
        rec = subset(anual, :municipality => ByRow(==("Recife")))
        @test rec.value[1] == sum([55,48,60,52,49,58,61,50,47,53,56,59])

        cat = DeBRief._assemble_vde(VDE_FIXTURE; category = "drugs", progress = false)
        @test all(==("drugs"), cat.category)

        mun = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE",
                                    municipality = "petrolina", progress = false)
        @test all(==("Petrolina"), mun.municipality)

        # Aviso direcionado: indicador só-estadual + filtro municipal = 0 linhas
        @test_logs (:warn, r"STATE-level totals") match_mode = :any begin
            out = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE",
                                        municipality = "Recife",
                                        typology = "roubo de carga",
                                        progress = false)
            @test nrow(out) == 0
        end
        # Aviso de deriva de vocabulário: tipologia canônica ausente do recorte
        @test_logs (:warn, r"matched no rows") match_mode = :any begin
            out = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE",
                                        typology = "Tráfico de drogas",
                                        progress = false)
            @test nrow(out) == 0
        end

        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         state = "ZZ", progress = false)
        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         typology = "nada", progress = false)
        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         category = "nada", progress = false)
        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         year = 1990, progress = false)
        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         granularity = :day, progress = false)
        @test_throws ArgumentError DeBRief._assemble_vde(VDE_FIXTURE;
                                                         municipality = [1, "Recife"],
                                                         progress = false)
    end

    @testset "classic Sinesp parsing and assembly (fixture)" begin
        df = DeBRief._parse_sinesp(SINESP_FIXTURE)
        @test Set(df.state) == Set(["PE", "BA"])   # nome por extenso -> sigla
        @test all(==(:occurrences), df.measure)
        @test Date(2021, 3, 1) in df.date          # "março" -> 3

        pe = DeBRief._assemble_sinesp(SINESP_FIXTURE; state = "pernambuco",
                                      typology = "roubo de veiculo", progress = false)
        @test all(==("PE"), pe.state)
        @test nrow(pe) == 24
        @test !hasproperty(pe, :female)            # série clássica não tem sexo

        anual = DeBRief._assemble_sinesp(SINESP_FIXTURE; year = 2022,
                                         granularity = :year, progress = false)
        @test all(==(2022), anual.year)
        @test_throws ArgumentError DeBRief._assemble_sinesp(SINESP_FIXTURE;
                                                            year = 2023, progress = false)
    end

    @testset "SIDRA parsing and rates (fixtures, offline)" begin
        uf_rows = DeBRief._parse_sidra(read(joinpath(FIX, "sidra_uf_fixture.json"), String))
        @test length(uf_rows) == 3                 # objeto-cabeçalho descartado
        @test (code = "26", name = "Pernambuco", value = 9058931) in uf_rows

        # Validação de integridade: fixture íntegra passa; truncada, não
        whole = read(joinpath(FIX, "sidra_mun_fixture.json"), String)
        @test DeBRief._sidra_ok(whole)
        @test !DeBRief._sidra_ok(first(whole, length(whole) ÷ 2))  # truncada
        @test !DeBRief._sidra_ok("Tabela 6579: parâmetro inválido")

        mun_rows = DeBRief._parse_sidra(read(joinpath(FIX, "sidra_mun_fixture.json"), String))
        @test length(mun_rows) == 5
        @test DeBRief._mun_name_uf("2611101", "Petrolina (PE)") == ("Petrolina", "PE")
        @test DeBRief._mun_name_uf("2611101", "Petrolina - PE") == ("Petrolina", "PE")
        @test DeBRief._mun_name_uf("2611101", "Petrolina") == ("Petrolina", "PE")
        @test DeBRief._mun_name_uf("3550308", "São Paulo") == ("São Paulo", "SP")

        # _add_rate! com lookup injetado (sem rede)
        df = DeBRief._assemble_vde(VDE_FIXTURE; state = "PE", municipality = "Recife",
                                   typology = "Homicídio doloso",
                                   granularity = :year, progress = false)
        pops = Dict(2023 => Dict("recife|PE" => 1_488_920))
        DeBRief._add_rate!(df, pops, row -> DeBRief.normalize_key(row.municipality) *
                                            "|" * row.state)
        @test hasproperty(df, :rate_100k)
        @test eltype(df.rate_100k) == Float64
        @test df.rate_100k[1] ≈ df.value[1] / 1_488_920 * 100_000
    end

    @testset "fuzz: filters never raise uninformative errors" begin
        # Combinações aleatórias de state/year/typology (válidas e inválidas):
        # o resultado deve ser um DataFrame ou um ArgumentError com mensagem —
        # nunca MethodError/BoundsError/KeyError.
        rng = MersenneTwister(42)
        states = [nothing, "PE", "pe", "Pernambuco", ["PE", "BA"], "ZZ", "Bahia"]
        years = [nothing, 2023, [2023], 2015:2023, 1990, 2050]
        typs = [nothing, "homicídio doloso", "ESTUPRO", ["Roubo de veículo", "latrocinio"],
                "crime inexistente", "Apreensão de Cocaína"]
        cats = [nothing, "drugs", "victims", "categoria errada"]
        grans = [:month, :year, :week]
        for _ in 1:120
            kw = (state = rand(rng, states), year = rand(rng, years),
                  typology = rand(rng, typs), category = rand(rng, cats),
                  granularity = rand(rng, grans))
            try
                out = DeBRief._assemble_vde(VDE_FIXTURE; progress = false, kw...)
                @test out isa DataFrame
            catch err
                @test err isa ArgumentError
                @test !isempty(sprint(showerror, err))
            end
        end
    end

    if get(ENV, "DEBRIEF_ONLINE_TESTS", "false") == "true"
        @testset "online (opt-in via DEBRIEF_ONLINE_TESTS)" begin
            df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso")
            @test df isa DataFrame && nrow(df) > 0
            @test all(==("PE"), df.state)
            @test all(==("Homicídio doloso"), df.typology)

            rel = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso",
                            granularity = :year, relative = true)
            @test hasproperty(rel, :rate_100k)
            @test all(r -> ismissing(r) || r isa Float64, rel.rate_100k)
            @test all(r -> ismissing(r) || 0 <= r <= 200, rel.rate_100k)  # sanidade

            classic = fetch_sinesp(state = "PE", year = 2022,
                                   typology = "roubo de veículo")
            @test classic isa DataFrame && nrow(classic) > 0
        end
    end

end
