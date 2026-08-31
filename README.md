# DeBRief.jl

[![CI](https://github.com/dantebertuzzi/DeBRief.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/dantebertuzzi/DeBRief.jl/actions/workflows/CI.yml)
[![version](https://juliahub.com/docs/General/DeBRief/stable/version.svg)](https://juliahub.com/ui/Packages/General/DeBRief)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://dantebertuzzi.github.io/DeBRief.jl/stable/)
[![docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://dantebertuzzi.github.io/DeBRief.jl/dev/)
[![DOI](https://zenodo.org/badge/DOI/10.5281/zenodo.22182421.svg)](https://doi.org/10.5281/zenodo.22182421)

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

## Example 2 — choropleth of latrocínio rate by state (classic series, ≤ 2022)

Loading `GeoJSON` activates the package extension, enabling
`geometry = true` (IBGE meshes, cached on disk). The **classic** series is
already state-level, so `geometry = true` joins the state meshes directly:

```julia
using GeoJSON, DeBRief, CairoMakie

df = fetch_sinesp(year = 2022, typology = "latrocínio",
                  granularity = :year, relative = true, geometry = true)

fig = Figure(size = (800, 800))
ax = Axis(fig[1, 1]; title = "Latrocínio per 100k inhabitants — 2022 (classic Sinesp)",
          aspect = DataAspect())
hidedecorations!(ax); hidespines!(ax)
poly!(ax, df.geometry; color = df.rate_100k, colormap = :magma)
Colorbar(fig[1, 2]; colormap = :magma, limits = extrema(skipmissing(df.rate_100k)))
save("latrocinio_uf_2022.png", fig; px_per_unit = 2)
```

## Example 2b — same map for a year after 2022 (VDE, aggregated to state)

The classic series ends in **2022**; for later years use `fetch_vde`. But
the VDE is **municipality-level**, so a state map needs an explicit
aggregation — sum municipalities per state, then attach the state mesh:

```julia
using GeoJSON, DeBRief, DataFrames, CairoMakie

# Latrocínio victims per state in 2025 (summed from municipalities) + rate
mun = fetch_vde(year = 2025, typology = "latrocínio",
                granularity = :year, refresh = true)   # 2025 is revised often
uf  = combine(groupby(mun, :state), :value => sum ∘ skipmissing => :value)

pop = DeBRief._population_by_uf(2025; progress = false)
uf.rate_100k = [uf.value[i] / pop[uf.state[i]] * 100_000 for i in 1:nrow(uf)]

# Attach the IBGE state mesh (same internal mechanism as the geo extension)
uf = DeBRief._attach_geometry(uf, :state)

ok = subset(uf, :geometry => ByRow(!ismissing))
fig = Figure(size = (800, 800))
ax = Axis(fig[1, 1]; title = "Latrocínio per 100k inhabitants — 2025 (Sinesp-VDE)",
          aspect = DataAspect())
hidedecorations!(ax); hidespines!(ax)
poly!(ax, ok.geometry; color = Float64.(coalesce.(ok.rate_100k, NaN)), colormap = :magma)
Colorbar(fig[1, 2]; colormap = :magma, limits = extrema(skipmissing(uf.rate_100k)))
save("latrocinio_uf_2025.png", fig; px_per_unit = 2)
```

> **Note.** `fetch_sinesp` (2022, **occurrences**) and `fetch_vde` (2025,
> **victims**) are different measurement rulers, not one continuous series —
> do not put the two maps side by side as if comparable. This is the same
> methodological break the package refuses to paper over.

## Example 3 — comparing municipalities within a state

```julia
using DeBRief, DataFrames

df = fetch_vde(state = "PE",
               municipality = ["Recife", "Petrolina", "Caruaru"],
               year = 2023, typology = "homicídio doloso",
               granularity = :year, relative = true)

sort(select(df, :municipality, :value, :rate_100k), :rate_100k, rev = true)
```

Municipality names are matched ignoring case and accents. Names are **not
unique across Brazilian states** — combine with `state`, or pass 7-digit IBGE
codes (`municipality = [2611101]`), to disambiguate.

> **Municipal coverage varies.** Some states report some indicators only as
> state totals (`municipality = "NÃO INFORMADO"`) — e.g. PE reports vehicle
> robbery this way in 2023. A municipality filter on such an indicator
> returns no rows, and DeBRief warns you to drop the filter for the state
> aggregate.

## Data sources and caveats

- **Origin.** Data are reported by state statistics managers to the MJSP via
  the Sinesp VDE (Validador de Dados Estatísticos) and published as annual
  spreadsheets on [gov.br](https://www.gov.br/mj/pt-br/assuntos/sua-seguranca/seguranca-publica/estatistica)
  and on the [MJSP open-data portal](https://www.gov.br/mj/pt-br/acesso-a-informacao/dados-abertos/ocorrencias-criminais-sinesp).
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

## How to cite

If DeBRief.jl was part of your analysis pipeline, cite **two things
separately**: the software and the data. They are distinct objects with
distinct responsibilities — the package answers for downloading, normalizing
and typing, the MJSP answers for the content.

### 1. The software

The repository ships a [`CITATION.cff`](CITATION.cff), which GitHub reads
natively: the **"Cite this repository"** button in the sidebar generates ready
APA and BibTeX. A [`CITATION.bib`](CITATION.bib) is also provided:

```bibtex
@software{bertuzzi_debrief_2026,
  author  = {Bertuzzi, Dante},
  title   = {{DeBRief.jl}: a {Julia} client for {Brazilian} public-security
             statistics ({Sinesp}/{MJSP})},
  year    = {2026},
  version = {0.1.3},
  doi     = {10.5281/zenodo.22182421},
  url     = {https://github.com/dantebertuzzi/DeBRief.jl},
  note    = {Julia package}
}
```

**Cite the version you used**, not "the latest". The normalization layer is
part of the result: which typology labels map onto which canonical name, and
how a layout change in an upstream spreadsheet is absorbed, can differ between
releases. Run `pkg> status DeBRief` and use the number it prints.

### 2. The Sinesp/MJSP data

The MJSP is the primary source and must be cited as such, **with the
extraction date** — states revise their figures retroactively, and the same
query run on different dates can return different numbers:

> BRASIL. Ministério da Justiça e Segurança Pública. *Sinesp — Dados
> Nacionais de Segurança Pública*: base de dados. Brasília: MJSP, 2026.
> Available at: https://www.gov.br/mj/pt-br/acesso-a-informacao/dados-abertos/ocorrencias-criminais-sinesp.
> Accessed: 30 Aug. 2026.

State **which of the two series** you used — they are not interchangeable:
`fetch_vde` (Sinesp-VDE, 2015–present, monthly, municipality-level) or
`fetch_sinesp` (classic series, 2015–2022, annual, state-level). See
[docs/src/harmonization.md](docs/src/harmonization.md). If you reported
`rate_100k`, also cite the population denominator: IBGE/SIDRA table 6579
(annual municipal population estimates).

### 3. Reproducibility

So that someone else reaches your number, record in the paper or supplementary
material: the **DeBRief.jl and Julia versions**; the `Project.toml` and
`Manifest.toml` of the environment (the `Manifest.toml` pins the whole
dependency tree and is what makes the environment reconstructible with
`Pkg.instantiate()`); the **extraction date** of the Sinesp files (and whether
you passed `refresh = true` or worked from an older cache); which series you
queried; and, for rates, the IBGE estimate year.

### The standards behind this

| Standard | What it establishes |
|---|---|
| [FORCE11 — Software Citation Principles](https://force11.org/info/software-citation-principles-published-2016/) | Software is a citable research product. Six principles: importance, credit, unique identification, persistence, accessibility and **specificity** (cite the exact version). |
| [Citation File Format (CFF) 1.2.0](https://citation-file-format.github.io/) | Machine-readable citation metadata. What GitHub and Zenodo consume. |
| ABNT NBR 6023:2018 | References in Brazilian publications; requires `Disponível em` + `Acesso em` for electronic documents. |
| [Zenodo + GitHub](https://docs.github.com/en/repositories/archiving-a-github-repository/referencing-and-citing-content) | Mints a persistent DOI per release, plus a *concept DOI* always pointing at the newest version. |

**The DOIs of this project**: the repository is connected to
[Zenodo](https://zenodo.org), so every release is archived and gets a
persistent identifier — the citation no longer depends on the GitHub URL
surviving a rename or a transfer. Two DOIs coexist, and they are not
interchangeable:

| DOI | What it identifies |
|---|---|
| [10.5281/zenodo.22182421](https://doi.org/10.5281/zenodo.22182421) | *Concept DOI* — the project as a whole. Always resolves to the newest version; it is what the badge at the top of this README points at. |
| one per release | Each archived version gets its own — 0.1.3 is [10.5281/zenodo.22182422](https://doi.org/10.5281/zenodo.22182422). All of them are listed on the [Zenodo page](https://doi.org/10.5281/zenodo.22182421). |

The BibTeX above carries the concept DOI, so it keeps working across releases.
**In a paper, swap it for the DOI of the version you used**: the concept DOI
says which project you used, the version DOI says which code actually ran.

## Development

```julia
] test DeBRief                          # offline tests (fixtures + Aqua)
ENV["DEBRIEF_ONLINE_TESTS"] = "true"    # opt into real-download tests
```
