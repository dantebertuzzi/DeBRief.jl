# DeBRief.jl

*A debrief on Brazilian crime data — with **BR** right in the middle.*

DeBRief.jl downloads, cleans and organizes Brazil's official crime and
violence statistics — the numbers that state governments report to the
Ministry of Justice and Public Security (MJSP) through the **Sinesp**
platform — and hands them to you as a tidy Julia `DataFrame`, ready for
analysis.

You do **not** need to know anything about the government's spreadsheets,
their changing layouts, or where they are published. That is the package's
job. You ask for *"intentional homicides in Pernambuco in 2023"* and get a
table back.

## What data is available?

Two official sources, exposed by two functions:

| Function | Source | Coverage | Detail level |
|:---|:---|:---|:---|
| [`fetch_vde`](@ref) | Sinesp-VDE (current system) | 2015 → today | every **municipality**, every **month**, 28 indicators |
| [`fetch_sinesp`](@ref) | classic Sinesp (legacy system) | 2015 → 2022 | every **state**, every **month**, 9 crime types |

Indicators include intentional homicide, femicide, rape, vehicle robbery
and theft, cargo robbery, drug seizures, missing persons, and more — the
full list is one call away: [`typologies`](@ref).

!!! warning "The two sources do not agree with each other"
    They come from different collection systems and are deliberately kept
    separate. Never splice them into one continuous series. The details are
    in [Data harmonization](@ref).

## Where to go next

- Never used Julia or this package before? Start with the
  [Tutorial (beginners)](@ref tutorial).
- Prefere português? Veja o [Guia rápido em português](@ref guia-pt).
- Already comfortable? The [User guide](@ref guide) covers filters, rates
  per 100k inhabitants, maps, and the disk cache.
- Full function-by-function details: [API reference](@ref reference).

## Installation

```julia
julia> ]           # entra no modo de pacotes
pkg> add DeBRief
```

## Thirty-second example

```julia
using DeBRief

df = fetch_vde(state = "PE", year = 2023, typology = "homicídio doloso")
```

The first call downloads the official spreadsheets and caches them on disk;
every later call reads from the cache and is much faster.

## Not affiliated with the government

DeBRief.jl is an independent open-source project. It has no ties to, or
endorsement from, the MJSP or the Brazilian government. Figures reflect
each state's reporting at extraction time and are revised retroactively by
the ministry.
