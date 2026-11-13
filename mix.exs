defmodule Xbase.MixProject do
  use Mix.Project

  def project do
    [
      app: :xbase,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      
      # Docs
      name: "Xbase",
      description: "A comprehensive Elixir library for reading, writing, and manipulating xBase database files",
      source_url: "https://github.com/pcharbon70/xbase",
      homepage_url: "https://github.com/your-org/xbase",
      docs: [
        main: "Xbase",
        extras: [
          "README.md",
          "docs/guides/getting_started.md",
          "docs/guides/memo_fields.md",
          "docs/guides/indexes.md",
          "docs/guides/streaming.md",
          "docs/guides/performance.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          "Guides": ~r/docs\/guides\/.*/
        ],
        groups_for_modules: [
          "Core": [Xbase.Parser, Xbase.Types],
          "Memo Support": [Xbase.MemoHandler, Xbase.DbtParser, Xbase.DbtWriter, Xbase.FptParser],
          "Field Handling": [Xbase.FieldParser, Xbase.FieldEncoder, Xbase.CodePage],
          "Index Support": [Xbase.CdxParser]
        ]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Pasal Charbonneau"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/pcharbon70/xbase",
        "Changelog" => "https://github.com/pcharbon70/xbase/blob/main/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end
end
