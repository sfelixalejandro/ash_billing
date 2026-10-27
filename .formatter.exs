spark_locals_without_parens = [customer_id_attribute: 1, customer_relationship: 1, provider: 1]

# Used by "mix format"
[
  import_deps: [:ash, :spark, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test,examples}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
