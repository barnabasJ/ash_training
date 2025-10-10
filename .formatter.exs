[
  import_deps: [
    :ash_ai,
    :ecto,
    :ecto_sql,
    :phoenix,
    :ash,
    :ash_postgres,
    :ash_authentication,
    :ash_authentication_phoenix,
    :ash_json_api,
    :ash_graphql,
    :ash_admin
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter, Spark.Formatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
