# [Guia rápido em português](@id guia-pt)

O DeBRief.jl baixa e organiza as estatísticas oficiais de criminalidade do
Brasil — os dados que os estados reportam ao Ministério da Justiça e
Segurança Pública (Sinesp) — e entrega tudo como uma tabela (`DataFrame`)
pronta para análise. Você não precisa saber onde o governo publica as
planilhas nem lidar com as mudanças de formato delas: esse trabalho é do
pacote.

## Instalação

No Julia, aperte `]` para entrar no modo de pacotes e digite:

```
pkg> add DeBRief
```

## Primeiro uso

```julia
using DeBRief

df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso")
```

Na primeira vez o pacote baixa a planilha oficial de 2023 e guarda no seu
disco (cache); nas próximas, lê direto do cache e é muito mais rápido.

Cada linha da tabela é **um município, em um mês, para um indicador**:

| Coluna | O que significa |
|:---|:---|
| `date` | o mês de referência (sempre o dia 1º) |
| `state` | sigla da UF (`"PE"`) |
| `municipality` | o município, escrito como na fonte (MAIÚSCULAS) |
| `typology` | qual indicador a linha conta |
| `category` | agrupamento mais amplo (mortes, drogas, bombeiros…) |
| `measure` | a **unidade**: `:victims` (vítimas), `:occurrences` (ocorrências), `:kg` (quilos apreendidos)… |
| `value` | o número em si, na unidade indicada por `measure` |
| `female`/`male`/`unspecified` | vítimas por sexo, quando a fonte informa |

!!! tip "Escreva do seu jeito"
    Os filtros ignoram maiúsculas e acentos: `"homicidio doloso"` funciona.
    Errou o nome do indicador? A mensagem de erro lista todas as opções
    válidas. Para ver a lista antes: `typologies()`.

## Perguntas comuns

**Quais indicadores existem?**

```julia
typologies()          # os 29 da base atual (VDE)
typologies(:sinesp)   # os 9 da série histórica por UF (2015–2022)
```

**Como pego a taxa por 100 mil habitantes?** Use `relative = true` — o
pacote busca a população oficial do IBGE e calcula para você:

```julia
pe = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso",
               granularity = :year, relative = true)
sort(select(pe, :municipality, :value, :rate_100k), :rate_100k, rev = true)
```

(`granularity = :year` soma os doze meses; `rate_100k` permite comparar
cidades de tamanhos diferentes.)

**Quanto espaço isso ocupa? Como apago?**

```julia
info = cache_info()   # lista cada arquivo do cache e o tamanho em MiB
sum(info.mb)          # total
clear_cache()         # apaga tudo; o próximo fetch baixa de novo
```

**Os números vão bater com o site da secretaria do meu estado?**
Provavelmente não, e isso não é erro: as secretarias coletam na ponta e
publicam indicadores compostos próprios (como o CVLI), enquanto o Sinesp é
o repasse validado ao ministério, com tipologias separadas. As tendências
coincidem; os valores absolutos, raramente. Detalhes na página
[Data harmonization](@ref).

**Posso emendar a série antiga (2015–2022) com a atual?** Não sem cuidado —
são metodologias diferentes, e o pacote as mantém separadas de propósito
([`fetch_sinesp`](@ref) vs. [`fetch_vde`](@ref)). Trate a passagem
2022/2023 como quebra estrutural na sua análise.

**Buscar tudo de uma vez trava?** `fetch_vde()` sem filtro nenhum devolve o
painel completo do Brasil desde 2015 — milhões de linhas. A memória é
controlada (leitura em streaming), mas o processamento leva alguns minutos.
Para trabalho interativo, filtre por `year`/`state` primeiro.

## Exemplo completo: gráfico e planilha

```julia
using DeBRief, DataFrames, CairoMakie, CSV

petrolina = fetch_vde(state = "PE", municipality = "Petrolina",
                      year = 2023, typology = "homicídio doloso")

mensal = combine(groupby(petrolina, :date), :value => sum => :vitimas)
lines(mensal.date, mensal.vitimas;
      axis = (title = "Homicídios em Petrolina, 2023",
              xlabel = "mês", ylabel = "vítimas"))

CSV.write("petrolina_2023.csv", petrolina)   # abre no Excel/LibreOffice
```
