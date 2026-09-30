defmodule GamendWeb.ApiShapeTest do
  # The OpenAPI document against the response shapes in
  # docs/specs/api-conventions.md (R15, R16). `GamendWeb.ResponseContract`
  # holds each response to its documented schema; this holds the documented
  # schemas to the four shapes, so between them a response in a fifth shape
  # fails the suite.
  use ExUnit.Case, async: true

  alias OpenApiSpex.{MediaType, Operation, PathItem, Reference, Response, Schema}

  @verbs [:get, :put, :post, :delete, :patch]

  # R16: a `<role>_name` names a person. Add a role here only for a person.
  @person_roles ~w(display sender user host creator recipient reporter reported_user
                   resolved_by muted_by leader)

  setup_all do
    spec = GamendWeb.ApiSpec.spec()

    operations =
      for {_path, %PathItem{} = item} <- spec.paths,
          verb <- @verbs,
          %Operation{} = operation <- [Map.get(item, verb)],
          do: operation

    %{schemas: spec.components.schemas, operations: operations}
  end

  test "every success response is a named Resource, Page or Done", ctx do
    problems =
      for operation <- ctx.operations,
          {status, schema} <- json_responses(operation),
          success?(status),
          problem = success_problem(schema, ctx.schemas),
          do: "#{operation.operationId} #{status}: #{problem}"

    assert problems == [], Enum.join(problems, "\n")
  end

  test "every error response is ErrorResponse", ctx do
    problems =
      for operation <- ctx.operations,
          {status, schema} <- json_responses(operation),
          not success?(status),
          not match?(%Reference{"$ref": "#/components/schemas/ErrorResponse"}, schema),
          do: "#{operation.operationId} #{status}"

    assert problems == [], "document these as ErrorResponse:\n" <> Enum.join(problems, "\n")
  end

  test "a person is <role>_name and a thing has a title (R16)", ctx do
    names =
      ctx.operations
      |> Enum.flat_map(&json_responses/1)
      |> Enum.flat_map(fn {_status, schema} ->
        property_names(schema, ctx.schemas, MapSet.new())
      end)
      |> Enum.uniq()

    wrong =
      Enum.filter(names, fn name ->
        name == "name" or
          (String.ends_with?(name, "_name") and
             String.trim_trailing(name, "_name") not in @person_roles)
      end)

    assert wrong == [], "rename (a thing has a title): #{inspect(wrong)}"
  end

  test "a string is never null, except a date or date-time (R6)", ctx do
    wrong =
      ctx.operations
      |> Enum.flat_map(&json_responses/1)
      |> Enum.flat_map(fn {_status, schema} ->
        nullable_strings(schema, ctx.schemas, MapSet.new())
      end)
      |> Enum.uniq()
      |> Enum.sort()

    assert wrong == [], "coalesce to \"\" and drop nullable: #{inspect(wrong)}"
  end

  # ── shapes ───────────────────────────────────────────────────────────────

  defp success_problem(%Reference{"$ref": "#/components/schemas/" <> name}, schemas) do
    case Map.fetch!(schemas, name) do
      %Schema{title: "OkResponse"} -> nil
      %Schema{} = schema -> envelope_problem(schema, schemas)
    end
  end

  defp success_problem(_inline, _schemas), do: "not a named component"

  defp envelope_problem(%Schema{properties: properties, required: required}, schemas)
       when is_map(properties) do
    keys = properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    cond do
      keys not in [["data"], ["data", "meta"]] ->
        "top level is #{inspect(keys)}, not data (+ meta)"

      :data not in (required || []) ->
        "data is not required"

      true ->
        data = resolve(properties.data, schemas)
        meta = properties[:meta] && resolve(properties.meta, schemas)
        data_problem(data, meta, properties[:meta])
    end
  end

  defp envelope_problem(_schema, _schemas), do: "has no properties"

  # An array under data is a page, unless it is a vocabulary of enum strings.
  defp data_problem(%Schema{type: :array, items: items}, nil, nil) do
    if vocabulary?(items), do: nil, else: "a list without meta"
  end

  defp data_problem(%Schema{type: :array}, _meta, raw_meta) do
    if page_meta?(raw_meta), do: nil, else: "meta is not PageMeta"
  end

  defp data_problem(_object, nil, nil), do: nil

  # Two lists in one answer: one PageMeta per list.
  defp data_problem(_object, %Schema{properties: %{} = per_list}, _raw) do
    if Enum.all?(Map.values(per_list), &page_meta?/1),
      do: nil,
      else: "meta beside an object must hold one PageMeta per list"
  end

  defp data_problem(_object, _meta, _raw), do: "meta beside an object must hold PageMeta"

  defp vocabulary?(%Schema{type: :string, enum: [_ | _]}), do: true
  defp vocabulary?(_items), do: false

  defp page_meta?(%Reference{"$ref": "#/components/schemas/PageMeta"}), do: true
  defp page_meta?(_schema), do: false

  # ── walking ──────────────────────────────────────────────────────────────

  defp json_responses(%Operation{responses: responses}) do
    for {status, %Response{content: %{"application/json" => %MediaType{schema: schema}}}} <-
          responses || %{},
        not is_nil(schema),
        do: {to_string(status), schema}
  end

  defp success?(status), do: String.starts_with?(status, "2")

  defp resolve(%Reference{"$ref": "#/components/schemas/" <> name}, schemas),
    do: Map.fetch!(schemas, name)

  defp resolve(schema, _schemas), do: schema

  defp property_names(%Reference{"$ref": "#/components/schemas/" <> name} = ref, schemas, seen) do
    if MapSet.member?(seen, name),
      do: [],
      else: property_names(resolve(ref, schemas), schemas, MapSet.put(seen, name))
  end

  defp property_names(%Schema{} = schema, schemas, seen) do
    own = Enum.map(Map.keys(schema.properties || %{}), &to_string/1)

    children =
      Map.values(schema.properties || %{}) ++
        List.wrap(schema.items) ++
        List.wrap(
          if is_struct(schema.additionalProperties, Schema), do: schema.additionalProperties
        )

    own ++ Enum.flat_map(children, &property_names(&1, schemas, seen))
  end

  defp property_names(_other, _schemas, _seen), do: []

  # `Owner.property` for every nullable string that is not a date or date-time.
  defp nullable_strings(%Reference{"$ref": "#/components/schemas/" <> name} = ref, schemas, seen) do
    if MapSet.member?(seen, name),
      do: [],
      else: nullable_strings(resolve(ref, schemas), schemas, MapSet.put(seen, name))
  end

  defp nullable_strings(%Schema{} = schema, schemas, seen) do
    own =
      for {key, %Schema{type: :string, nullable: true, format: format}} <-
            schema.properties || %{},
          format not in [:date, :"date-time", "date", "date-time"],
          do: "#{schema.title || "inline"}.#{key}"

    children =
      Map.values(schema.properties || %{}) ++
        List.wrap(schema.items) ++
        List.wrap(schema.allOf) ++
        List.wrap(
          if is_struct(schema.additionalProperties, Schema), do: schema.additionalProperties
        )

    own ++ Enum.flat_map(children, &nullable_strings(&1, schemas, seen))
  end

  defp nullable_strings(_other, _schemas, _seen), do: []
end
