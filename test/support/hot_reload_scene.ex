defmodule Lunity.HotReloadTest.Scene do
  @moduledoc false
  use Lunity.Scene

  scene do
    node(:marker,
      prefab: Lunity.TestPrefab,
      entity: Lunity.HotReloadTest.Entity,
      position: {0.0, 0.0, 0.0}
    )
  end
end
