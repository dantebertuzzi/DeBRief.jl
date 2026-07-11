# DeBRief.jl

[![CI](https://github.com/USERNAME/DeBRief.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/USERNAME/DeBRief.jl/actions/workflows/CI.yml)
[![version](https://juliahub.com/docs/General/DeBRief/stable/version.svg)](https://juliahub.com/ui/Packages/General/DeBRief)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://USERNAME.github.io/DeBRief.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://USERNAME.github.io/DeBRief.jl/dev/)

*A debrief on Brazilian crime data — with **BR** right in the middle.*

DeBRief.jl is a Julia client for the crime and violence statistics published
by Brazil's Ministry of Justice and Public Security (MJSP) through the
**Sinesp** platform. It downloads, caches and normalizes two data sources:

- **Sinesp-VDE** (`fetch_vde`): the national public security database, 2015
  to the most recent year, **monthly and municipality-level**, 28 indicators
  (homicide, femicide, rape, vehicle robbery/theft, drug seizures, missing
  persons, fire department services, …).
- **Classic Sinesp** (`fetch_sinesp`): the historical state-level series,
  2015–2022, nine crime typologies.

The value of the package is the normalization layer: upstream files change
layout, typology vocabulary and methodology across years; DeBRief gives you a
single stable schema, tolerant (case/accent-insensitive) filters, disk
caching, and per-100k rates using IBGE/SIDRA population estimates. The two
sources are **never silently merged** — see
[docs/src/harmonization.md](docs/src/harmonization.md).

## Installation

```julia
] add DeBRief
```

## Quick start

```julia
using DeBRief

df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso")
typologies(:vde)    # canonical indicator names
clear_cache()       # drop cached raw files
```

Every fetch returns a `DataFrame` in long format with typed columns —
`date::Date`, `value::Int`/`Float64`, `measure::Symbol` (`:victims`,
`:occurrences`, `:kg`, …) — and `missing` where the source does not report.

## Example 1 — monthly intentional homicides in Pernambuco, 2015–2024

```julia
using DeBRief, DataFrames, CairoMakie

df = fetch_vde(state = "PE", year = 2015:2024, typology = "homicídio doloso")
pe = combine(groupby(df, :date), :value => sum => :victims)

with_theme(theme_dark()) do  # or your Dracula theme of choice
    fig = Figure(size = (1000, 450))
    ax = Axis(fig[1, 1]; title = "Intentional homicides — Pernambuco",
              xlabel = "month", ylabel = "victims")
    lines!(ax, pe.date, pe.victims; linewidth = 2, color = "#bd93f9")
    save("pe_homicides.png", fig; px_per_unit = 2)
    fig
end
```

## Example 2 — choropleth of robbery-followed-by-death rate by state

Loading `GeoDataFrames` activates the package extension, enabling
`geometry = true` (IBGE meshes, cached on disk):

```julia
using GeoDataFrames, DeBRief, CairoMakie

df = fetch_sinesp(year = 2022, typology = "latrocínio",
                  granularity = :year, relative = true, geometry = true)

fig = Figure(size = (800, 800))
ax = Axis(fig[1, 1]; title = "Latrocínio per 100k inhabitants — 2022", aspect = DataAspect())
hidedecorations!(ax); hidespines!(ax)
poly!(ax, df.geometry; color = df.rate_100k, colormap = :magma)
Colorbar(fig[1, 2]; colormap = :magma, limits = extrema(skipmissing(df.rate_100k)))
save("latrocinio_uf.png", fig; px_per_unit = 2)
```

## Example 3 — comparing municipalities within a state

```julia
using DeBRief, DataFrames

df = fetch_vde(state = "PE",
               municipality = ["Recife", "Petrolina", "Caruaru"],
               year = 2023, typology = "roubo de veículo",
               granularity = :year, relative = true)

sort(select(df, :municipality, :value, :rate_100k), :rate_100k, rev = true)
```

Municipality names are matched ignoring case and accents. Names are **not
unique across Brazilian states** — combine with `state`, or pass 7-digit IBGE
codes (`municipality = [2611101]`), to disambiguate.

## Data sources and caveats

- **Origin.** Data are reported by state statistics managers to the MJSP via
  the Sinesp VDE (Validador de Dados Estatísticos) and published as annual
  spreadsheets on [gov.br](https://www.gov.br/mj/pt-br/assuntos/sua-seguranca/seguranca-publica/estatistica)
  and on the [MJSP open-data portal](https://dados.mj.gov.br/dataset/sistema-nacional-de-estatisticas-de-seguranca-publica).
  Figures reflect each state's data-entry status at extraction time and are
  revised retroactively; use `refresh = true` or `clear_cache()` to pick up
  republished files.
- **Methodological break.** The classic series (2015–2022) and the VDE series
  (2015–present) come from different collection pipelines and disagree where
  they overlap. DeBRief exposes them as separate functions and does not
  stitch them together. Details in
  [docs/src/harmonization.md](docs/src/harmonization.md).
- **Units differ across indicators** (victims, occurrences, kilograms,
  services…): always group by the `measure` column before aggregating.
- **Rates** use IBGE/SIDRA annual population estimates (table 6579); monthly
  rows reuse the annual population (no monthly interpolation in v0.1.0).
- **No official affiliation.** This package is an independent open-source
  client and has no ties to, or endorsement from, the MJSP or the Brazilian
  government.

## Related work

DeBRief is analogous in purpose to the R package
[BrazilCrime](https://cran.r-project.org/package=BrazilCrime), but written as
an idiomatic Julia package rather than a line-by-line translation.

## Development

```julia
] test DeBRief                          # offline tests (fixtures + Aqua)
ENV["DEBRIEF_ONLINE_TESTS"] = "true"    # opt into real-download tests
```
