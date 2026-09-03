defmodule Swarm.Connector.GrpcCodec do
  @moduledoc """
  Converts between the ADR-21 connector gRPC schema and the in-kernel
  `Swarm.Ports.Connector.fetch/2` page shape.
  """

  alias Swarm.Connector.V1.{
    Cursor,
    Entity,
    Event,
    FetchOptions,
    FetchRequest,
    FetchResponse,
    FetchStatus,
    Page,
    Relation,
    Skip
  }

  @fetch_ok FetchStatus.value(:FETCH_OK)
  @fetch_error FetchStatus.value(:FETCH_ERROR)

  @spec request(term(), keyword()) :: FetchRequest.t()
  def request(cursor, opts) do
    %FetchRequest{cursor: encode_cursor(cursor), options: options(opts)}
  end

  @spec page(FetchResponse.t()) :: {:ok, map()} | {:error, term()}
  def page(%FetchResponse{status: @fetch_ok, page: %Page{} = page}) do
    {:ok, decode_page(page)}
  end

  def page(%FetchResponse{status: @fetch_error, error: error}) when is_binary(error) do
    {:error, {:connector_rpc_error, error}}
  end

  def page(%FetchResponse{status: status}) do
    {:error, {:unexpected_connector_status, status}}
  end

  @spec encode_page(map()) :: Page.t()
  def encode_page(page) when is_map(page) do
    %Page{
      events: Enum.map(Map.get(page, :events, []), &encode_event/1),
      cursor: encode_cursor(Map.get(page, :cursor, :done)),
      truncated: Map.get(page, :truncated?, false),
      skips: Enum.map(Map.get(page, :skips, []), &encode_skip/1),
      total: Map.get(page, :total, 0) || 0
    }
  end

  @spec encode_cursor(term()) :: Cursor.t()
  def encode_cursor(:start), do: %Cursor{start: true}
  def encode_cursor(:done), do: %Cursor{done: true}

  def encode_cursor(cursor) when is_map(cursor) do
    %Cursor{json: JSON.encode!(cursor)}
  end

  def encode_cursor(cursor), do: %Cursor{json: JSON.encode!(cursor)}

  @spec decode_cursor(Cursor.t() | nil) :: term()
  def decode_cursor(%Cursor{start: true}), do: :start
  def decode_cursor(%Cursor{done: true}), do: :done
  def decode_cursor(%Cursor{json: ""}), do: :done

  def decode_cursor(%Cursor{json: json}) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, cursor} -> cursor
      {:error, reason} -> raise ArgumentError, "bad connector cursor JSON: #{inspect(reason)}"
    end
  end

  def decode_cursor(nil), do: :done

  defp options(opts) do
    %FetchOptions{
      scope: Keyword.get(opts, :scope, ""),
      limit: uint_opt(opts, :limit),
      max_pages: uint_opt(opts, :max_pages),
      since: since(opts),
      source_options: source_options(opts)
    }
  end

  defp uint_opt(opts, key) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n >= 0 -> n
      n when is_binary(n) and n != "" -> String.to_integer(n)
      _ -> 0
    end
  end

  defp since(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp source_options(opts) do
    opts
    |> Keyword.drop([
      :address,
      :channel,
      :connect_fun,
      :fetch_fun,
      :max_retries,
      :scope,
      :limit,
      :max_pages,
      :since,
      :timeout
    ])
    |> Enum.reject(fn {_key, value} -> is_function(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp decode_page(%Page{} = page) do
    %{
      events: Enum.map(page.events, &decode_event/1),
      cursor: decode_cursor(page.cursor),
      truncated?: page.truncated,
      skips: Enum.map(page.skips, &decode_skip/1)
    }
    |> maybe_total(page.total)
  end

  defp maybe_total(page, total) when is_integer(total) and total > 0,
    do: Map.put(page, :total, total)

  defp maybe_total(page, _total), do: page

  defp encode_event(event) do
    %Event{
      provenance: string(event, :provenance),
      origin: string(event, :origin),
      source: string(event, :source),
      source_ref: string(event, :source_ref),
      occurred_at: occurred_at(event),
      entities: Enum.map(Map.get(event, :entities, []), &encode_entity/1),
      relations: Enum.map(Map.get(event, :relations, []), &encode_relation/1)
    }
  end

  defp decode_event(%Event{} = event) do
    %{
      provenance: event.provenance,
      origin: event.origin,
      source: event.source,
      source_ref: event.source_ref,
      occurred_at: event.occurred_at,
      entities: Enum.map(event.entities, &decode_entity/1),
      relations: Enum.map(event.relations, &decode_relation/1)
    }
  end

  defp encode_entity(entity) do
    %Entity{
      type: string(entity, :type),
      key: string(entity, :key),
      identity: string(entity, :identity),
      source_ref: string(entity, :source_ref),
      scope: string(entity, :scope),
      content: string(entity, :content)
    }
  end

  defp decode_entity(%Entity{} = entity) do
    %{
      type: entity.type,
      key: entity.key,
      identity: blank_nil(entity.identity),
      source_ref: blank_nil(entity.source_ref),
      scope: entity.scope,
      content: entity.content
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_relation(relation) do
    %Relation{
      from: string(relation, :from),
      to: string(relation, :to),
      from_ref: string(relation, :from_ref),
      to_ref: string(relation, :to_ref),
      type: string(relation, :type)
    }
  end

  defp decode_relation(%Relation{} = relation) do
    %{
      from: relation.from,
      to: relation.to,
      from_ref: blank_nil(relation.from_ref),
      to_ref: blank_nil(relation.to_ref),
      type: relation.type
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp encode_skip(skip) do
    %Skip{
      connector: string(skip, :connector),
      source: string(skip, :source),
      source_ref: string(skip, :source_ref),
      reason: string(skip, :reason),
      occurred_at: occurred_at(skip)
    }
  end

  defp decode_skip(%Skip{} = skip) do
    %{
      connector: blank_nil(skip.connector),
      source: blank_nil(skip.source),
      source_ref: skip.source_ref,
      reason: skip.reason,
      occurred_at: blank_nil(skip.occurred_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp string(map, key) do
    case Map.get(map, key) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp occurred_at(map) do
    case Map.get(map, :occurred_at) do
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      nil -> ""
      value -> to_string(value)
    end
  end

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value
end
