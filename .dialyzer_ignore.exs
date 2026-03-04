# Dialyzer ignore file. See https://hexdocs.pm/dialyxir/readme.html#ignore-warnings
# Format: list of {file, warning} | {file, warning, line} | etc.
[
  # ex_mcp macro expansion produces pattern_match warning at use ExMCP.Server
  {"lib/lunity/mcp/server.ex", :pattern_match}
]
