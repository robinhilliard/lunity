[
  # Cascading from luerl type mismatch in Mod.Loader.load_all
  {"lib/lunity/application.ex", :pattern_match},
  # luerl's Erlang typespecs declare string() (charlist) but accept binary() at runtime
  {"lib/lunity/mod/sandbox.ex", :call},
  {"lib/lunity/mod/sandbox.ex", :no_return},
  {"lib/lunity/mod/sandbox.ex", :unknown_type},
  {"lib/lunity/mod/sandbox.ex", :invalid_contract},
  {"lib/lunity/mod/data_stage.ex", :call},
  {"lib/lunity/mod/data_stage.ex", :no_return},
  {"lib/lunity/mod/data_stage.ex", :invalid_contract},
  {"lib/lunity/mod/event_bus.ex", :call},
  {"lib/lunity/mod/event_bus.ex", :no_return},
  {"lib/lunity/mod/resource_limits.ex", :call},
  {"lib/lunity/mod/resource_limits.ex", :no_return},
  {"lib/lunity/mod/resource_limits.ex", :unknown_type},
  {"lib/lunity/mod/resource_limits.ex", :invalid_contract},
  {"lib/lunity/mod.ex", :call},
  {"lib/lunity/mod.ex", :call_without_opaque},
  ~r/lib\/lunity\/mod.ex.*opaque/,
  {"lib/lunity/mod.ex", :unused_fun},
  {"lib/lunity/mod.ex", :pattern_match},
  {"lib/lunity/mod/runtime_stage.ex", :pattern_match},
  {"lib/lunity/mod/runtime_stage.ex", :unused_fun},
  {"lib/lunity/mod/loader.ex", :unused_fun},
  {"lib/lunity/mod/data_stage.ex", :unused_fun},
  {"lib/lunity/mod/resource_limits.ex", :unused_fun},
  # Mix modules not in PLT when running Dialyzer
  {"lib/lunity.ex", :unknown_function},
  {"lib/mix/tasks/lunity.edit.ex", :callback_info_missing},
  {"lib/mix/tasks/lunity.edit.ex", :unknown_function},
  # ExMCP deftool macro expansion
  {"lib/lunity/mcp/server.ex", :pattern_match}
]
