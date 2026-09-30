defmodule GamendWeb.SchemasTest do
  use ExUnit.Case, async: true

  # OpenApiSpex keys components by title and a clash silently keeps one, so a
  # second `Lobby` would replace the first in every generated SDK. The title is
  # also the module's last segment, so the name a generator emits can be found
  # in the code (docs/specs/named-api-schemas.md).
  test "every schema module's title is unique and is its module name" do
    {:ok, modules} = :application.get_key(:gamend_web, :modules)

    titles =
      for module <- modules,
          ["GamendWeb", "Schemas", name] <- [Module.split(module)],
          Code.ensure_loaded?(module),
          function_exported?(module, :schema, 0) do
        assert module.schema().title == name,
               "#{inspect(module)} is titled #{inspect(module.schema().title)}"

        name
      end

    assert titles != []
    assert titles -- Enum.uniq(titles) == []
  end
end
