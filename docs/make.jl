# Build da documentação (Documenter.jl). Local:
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# No CI, o workflow Documentation.yml publica em gh-pages automaticamente.

using DeBRief
using Documenter

DocMeta.setdocmeta!(DeBRief, :DocTestSetup, :(using DeBRief); recursive = true)

makedocs(
    modules = [DeBRief],
    authors = "Dante Bertuzzi and contributors",
    sitename = "DeBRief.jl",
    checkdocs = :exports,
    format = Documenter.HTML(
        canonical = "https://dantebertuzzi.github.io/DeBRief.jl",
        edit_link = "main",
        prettyurls = get(ENV, "CI", "false") == "true",
    ),
    pages = [
        "Home" => "index.md",
        "Tutorial (beginners)" => "tutorial.md",
        "Guia rápido em português" => "guia_pt.md",
        "User guide" => "guide.md",
        "Data harmonization" => "harmonization.md",
        "API reference" => "reference.md",
    ],
)

# Republicar a doc de uma tag já existente: rode o workflow Documentation
# manualmente informando a tag (ver Documentation.yml). É preciso porque as tags
# criadas pelo TagBot com o GITHUB_TOKEN não disparam workflows sozinhas.
deploy_tag = get(ENV, "DOCS_DEPLOY_TAG", "")
deploy_config = if isempty(deploy_tag)
    Documenter.auto_detect_deploy_system()
else
    Documenter.GitHubActions(
        ENV["GITHUB_REPOSITORY"],
        ENV["GITHUB_EVENT_NAME"],
        "refs/tags/" * deploy_tag,
    )
end

deploydocs(
    repo = "github.com/dantebertuzzi/DeBRief.jl",
    devbranch = "main",
    deploy_config = deploy_config,
)
