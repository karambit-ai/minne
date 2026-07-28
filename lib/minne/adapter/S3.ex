defmodule Minne.Adapter.S3 do
  require Logger
  @behaviour Minne.Adapter

  @min_chunk Application.compile_env(:minne, :chunk_size) || 5_242_880

  defstruct key: "",
            bucket: "",
            parts: [],
            parts_count: 0,
            upload_id: nil,
            hashes: %{},
            max_file_size: 0,
            path_function: nil,
            bucket_function: nil,
            private: nil

  @impl Minne.Adapter
  def default_opts, do: [length: 16_000_000_000, read_length: @min_chunk]

  @impl Minne.Adapter
  def init(upload, opts) do
    case {opts[:bucket_function], opts[:path_function], opts[:max_file_size]} do
      {nil, _, _} ->
        {:error, "bucket_function is required to use minne's s3 adapter"}

      {_, nil, _} ->
        {:error, "path_function is required to use minne's s3 adapter"}

      {_, _, nil} ->
        {:error, "max_file_size is required to use minne's s3 adapter"}

      {bucket_function, path_function, max_file_size} ->
        adapter = %{
          upload.adapter
          | bucket_function: bucket_function,
            path_function: path_function,
            max_file_size: max_file_size,
            hashes: new_hashes()
        }

        %{upload | adapter: adapter}
    end
  end

  @impl Minne.Adapter
  def start(upload, _opts) do
    {key, private?} = upload.adapter.path_function.(upload)
    bucket = upload.adapter.bucket_function.(upload)
    Logger.info("Minne: buffering upload for: #{bucket}/#{key}")
    %{upload | adapter: %{upload.adapter | key: key, bucket: bucket, private: private?}}
  end

  @impl Minne.Adapter
  def write_part(upload, chunk, size, _final?, _opts) do
    if upload.size + size > upload.adapter.max_file_size do
      abort(upload, [])
      {:error, :too_large}
    else
      upload = %{
        upload
        | size: upload.size + size,
          remainder_bytes: upload.remainder_bytes <> chunk,
          adapter: update_hashes(upload.adapter, chunk)
      }

      {:ok, flush_full_parts(upload)}
    end
  end

  @impl Minne.Adapter
  def close(%{adapter: %{upload_id: nil}} = upload, _opts) do
    if upload.size > upload.adapter.max_file_size, do: raise("upload exceeds max_file_size")
    client().put_object(upload.adapter.bucket, upload.adapter.key, upload.remainder_bytes)

    %{
      upload
      | remainder_bytes: "",
        adapter: finalize_hashes(upload.adapter)
    }
  end

  def close(upload, _opts) do
    upload = flush_remainder(upload)

    try do
      parts = upload.adapter.parts |> Enum.map(&await_part/1) |> Enum.reverse()

      client().complete_multipart_upload(
        upload.adapter.bucket,
        upload.adapter.key,
        upload.adapter.upload_id,
        parts
      )

      adapter = upload.adapter |> Map.put(:parts, parts) |> finalize_hashes()
      %{upload | adapter: adapter}
    rescue
      error ->
        abort(upload, [])
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        abort(upload, [])
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @impl Minne.Adapter
  def abort(%{adapter: %{upload_id: nil}}, _opts), do: :ok

  def abort(upload, _opts) do
    Enum.each(upload.adapter.parts, fn
      %Task{} = task -> Task.shutdown(task, :brutal_kill)
      _completed_part -> :ok
    end)

    client().abort_multipart_upload(
      upload.adapter.bucket,
      upload.adapter.key,
      upload.adapter.upload_id
    )

    :ok
  rescue
    error ->
      Logger.error("Minne: failed to abort multipart upload: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.error("Minne: failed to abort multipart upload: #{inspect({kind, reason})}")
      :ok
  end

  defp flush_full_parts(upload) when byte_size(upload.remainder_bytes) < @min_chunk, do: upload

  defp flush_full_parts(upload) do
    upload = ensure_upload_id(upload)
    <<chunk::binary-size(@min_chunk), remainder::binary>> = upload.remainder_bytes
    upload = enqueue_part(%{upload | remainder_bytes: remainder}, chunk)
    flush_full_parts(upload)
  end

  defp flush_remainder(%{remainder_bytes: ""} = upload), do: upload

  defp flush_remainder(upload) do
    chunk = upload.remainder_bytes
    enqueue_part(%{upload | remainder_bytes: ""}, chunk)
  end

  defp ensure_upload_id(%{adapter: %{upload_id: nil} = adapter} = upload) do
    %{body: %{upload_id: upload_id}} =
      client().initiate_multipart_upload(adapter.bucket, adapter.key)

    %{upload | adapter: %{adapter | upload_id: upload_id}}
  end

  defp ensure_upload_id(upload), do: upload

  defp enqueue_part(upload, chunk) do
    count = upload.adapter.parts_count + 1
    task = upload_async(upload, count, chunk)
    adapter = %{upload.adapter | parts_count: count, parts: [task | upload.adapter.parts]}
    %{upload | adapter: adapter}
  end

  defp upload_async(upload, number, chunk) do
    Task.async(fn ->
      try do
        %{headers: headers} =
          client().upload_part(
            upload.adapter.bucket,
            upload.adapter.key,
            upload.adapter.upload_id,
            number,
            chunk
          )

        {:ok, {number, Minne.get_header(headers, "ETag")}}
      rescue
        error -> {:error, :error, error, __STACKTRACE__}
      catch
        kind, reason -> {:error, kind, reason, __STACKTRACE__}
      end
    end)
  end

  defp await_part(task) do
    case Task.await(task, 10_000) do
      {:ok, part} -> part
      {:error, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp new_hashes do
    %{
      sha256: :crypto.hash_init(:sha256),
      sha1: :crypto.hash_init(:sha),
      md5: :crypto.hash_init(:md5)
    }
  end

  defp update_hashes(%{hashes: hashes} = adapter, chunk) do
    hashes = %{
      sha256: :crypto.hash_update(hashes.sha256, chunk),
      sha1: :crypto.hash_update(hashes.sha1, chunk),
      md5: :crypto.hash_update(hashes.md5, chunk)
    }

    %{adapter | hashes: hashes}
  end

  defp finalize_hashes(%{hashes: %{sha256: digest}} = adapter) when is_binary(digest),
    do: adapter

  defp finalize_hashes(%{hashes: hashes} = adapter) do
    hashes = %{
      sha256: encode_hash(hashes.sha256),
      sha1: encode_hash(hashes.sha1),
      md5: encode_hash(hashes.md5)
    }

    %{adapter | hashes: hashes}
  end

  defp encode_hash(state), do: state |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp client, do: Application.get_env(:minne, :s3_client, Minne.Clients.S3)
end
