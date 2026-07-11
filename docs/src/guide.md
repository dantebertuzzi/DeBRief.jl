# [User guide](@id guide)

Everything the package does, feature by feature. For a gentler start, see
the [Tutorial (beginners)](@ref tutorial).

## The two data sources

```julia
fetch_vde(...)      # Sinesp-VDE: 2015–present, municipality × month, 28 indicators
fetch_sinesp(...)   # classic Sinesp: 2015–2022, state × month, 9 typologies
```

Both return a long-format `DataFrame` with one row per place × month ×
indicator. They come from different collection systems and **disagree where
they overlap** — DeBRief never merges them (see [Data harmonization](@ref)).

## Filters

All filters are keyword arguments; omit any of them (or pass `nothing`) to
mean "everything". Every text match ignores case and accents.

```julia
fetch_vde(
    state        = "PE",                 # ou "Pernambuco", ou ["PE", "BA"]
    municipality = "Petrolina",          # nome, lista de nomes, ou códigos IBGE
    year         = 2020:2023,            # Int, vetor ou intervalo
    typology     = ["homicídio doloso", "feminicídio"],
    category     = "drugs",              # agrupamento amplo
    granularity  = :month,               # :month (padrão) ou :year
)
```

- **`state`** accepts abbreviations or full names, single or vector.
- **`municipality`** accepts names or 7-digit IBGE codes (e.g.
  `[2611101]` for Petrolina) — never both mixed. Names are **not unique
  across Brazil**; if a name matches cities in more than one state, DeBRief
  warns you to add `state` or switch to codes. Code resolution uses an
  IBGE registry fetched (and cached) from SIDRA.
- **`typology`** matches the canonical names from [`typologies`](@ref);
  spelling variants used by the government across years are harmonized
  automatically. Unknown values raise an error that lists all options.
- **`category`** groups indicators: `victims`, `occurrences`, `drugs`,
  `firearms`, `missing_persons`, `state_agents`, `warrants`, `fire_dept`.
- **`granularity = :year`** sums the months within each year (the `date`
  column is replaced by an integer `year` column).

Invalid arguments fail fast — before any file is parsed — with messages
that list the valid options.

## Understanding `measure` and `value`

The government mixes **units** across indicators: homicides count victims,
vehicle robbery counts police records, cocaine seizures count kilograms.
DeBRief encodes the unit in the `measure` column and puts the number in
`value`:

| `measure` | unit | example indicators |
|:---|:---|:---|
| `:victims` | people | Homicídio doloso, Estupro, Feminicídio |
| `:occurrences` | police records | Roubo de veículo, Tráfico de drogas |
| `:kg` | kilograms | Apreensão de Cocaína / Maconha |
| `:units` | items | Arma de Fogo Apreendida |
| `:people` | people | Pessoa Desaparecida / Localizada |
| `:warrants` | warrants | Mandado de prisão cumprido |
| `:services` | service calls | fire department indicators |

**Rule of thumb: always group by `measure` before summing `value`** —
adding victims to kilograms is meaningless:

```julia
using DataFrames
combine(groupby(df, [:typology, :measure]),
        :value => sum ∘ skipmissing => :total)
```

## Rates per 100k inhabitants

`relative = true` adds a `rate_100k` column using official IBGE/SIDRA
population estimates (table 6579), fetched and cached automatically:

```julia
fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso",
          granularity = :year, relative = true)
```

Details you should know for serious work:

- monthly rows reuse the **annual** population of the matching year
  (no monthly interpolation in v0.1.x);
- years without a published estimate (e.g. the 2022 census year) fall back
  to the nearest available year, with a warning;
- rows whose population cannot be matched get `rate_100k = missing`
  (never a silent zero), with a summary warning.

## Maps (geo extension)

The core package has no geospatial dependencies. Loading
[GeoJSON.jl](https://github.com/JuliaGeo/GeoJSON.jl) activates a
package extension that enables `geometry = true`, joining official IBGE
meshes (cached on disk):

```julia
using GeoJSON, DeBRief   # a ordem não importa; ambos carregados

# Classic series is state-level → geometry = true joins the state meshes
uf = fetch_sinesp(year = 2022, typology = "latrocínio",
                  granularity = :year, relative = true, geometry = true)
# → coluna extra `geometry`, pronta para poly!() no Makie
```

For `fetch_vde`, geometry is **municipal**; rows whose municipality name
cannot be matched to the IBGE registry get `missing` geometry (with a
warning).

### State maps from VDE (years after 2022)

The classic series stops in 2022. For a **state** choropleth of a later
year, aggregate the municipal VDE data to UF level yourself, then attach the
state mesh via the same helper the extension uses:

```julia
using GeoJSON, DeBRief, DataFrames

mun = fetch_vde(year = 2025, typology = "latrocínio",
                granularity = :year, refresh = true)
uf  = combine(groupby(mun, :state), :value => sum ∘ skipmissing => :value)

pop = DeBRief._population_by_uf(2025; progress = false)
uf.rate_100k = [uf.value[i] / pop[uf.state[i]] * 100_000 for i in 1:nrow(uf)]

uf = DeBRief._attach_geometry(uf, :state)   # anexa a malha estadual
```

!!! warning "Different rulers"
    A `fetch_sinesp` map (occurrences, ≤ 2022) and a `fetch_vde` map
    (victims, ≥ 2023) measure different things. Label the source on each
    panel and never present them as one continuous series — see
    [Data harmonization](@ref).

## The disk cache

Raw government spreadsheets, SIDRA population responses and IBGE meshes are
cached on disk (via Scratch.jl), so downloads happen once:

```julia
info = cache_info()   # DataFrame: cada arquivo e seu tamanho em MiB
sum(info.mb)          # pegada total
clear_cache()         # apaga tudo
```

Three behaviors worth knowing:

- **Revisions**: the ministry revises published files retroactively. Use
  `refresh = true` on a fetch (or `clear_cache()`) to re-download.
- **Resume**: interrupted downloads leave a `.part` file and **resume from
  where they stopped** — including on the next call. The gov.br servers
  drop long connections often; just call the fetch again.
- **Reproducibility**: for papers, record the package version and the
  extraction date, since the upstream data itself changes.

## Performance notes

- A fully unfiltered `fetch_vde()` is the entire national panel — millions
  of rows. Files are read in streaming mode and filters are applied
  year-by-year, so memory stays bounded, but parsing all years takes
  minutes. Filter first, widen later.
- The expensive step is parsing XLSX, not downloading (after the first
  time). Within one session, fetch a broad slice once and cut it with
  `subset`/`groupby` in memory instead of re-fetching.

## Error handling philosophy

Bad input fails immediately with the valid options listed. Layout changes
in upstream files fail loudly, naming the file and the columns found.
Unknown future indicators are **not dropped**: they pass through with
`category = "other"`. Rows the source duplicates (an official quirk of
Tentativa de Homicídio and Estupro) are summed exactly as the ministry
instructs.
