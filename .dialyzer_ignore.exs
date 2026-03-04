# Dialyzer ignore file. See https://hexdocs.pm/dialyxir/readme.html#ignore-warnings
# Format: list of {file, warning} | {file, warning, line} | etc.
[
  # ex_mcp macro expansion at use ExMCP.Server produces pattern_match_cov (redundant _ clause in get_attribute_map)
  {"lib/lunity/mcp/server.ex", :pattern_match_cov}
]
