defmodule Minne.TestS3Client do
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    Agent.start_link(fn -> initial_state([]) end,
      name: __MODULE__
    )
  end

  def reset(failures \\ []) do
    Agent.update(__MODULE__, fn _ -> initial_state(failures) end)
  end

  def state, do: Agent.get(__MODULE__, & &1)

  def put_object(_bucket, _key, body) do
    Agent.update(__MODULE__, &%{&1 | put_bodies: [body | &1.put_bodies]})
    %{}
  end

  def initiate_multipart_upload(_bucket, _key) do
    Agent.update(__MODULE__, &Map.update!(&1, :initiate_count, fn count -> count + 1 end))
    %{body: %{upload_id: "upload-id"}}
  end

  def upload_part(_bucket, _key, _upload_id, _part_number, _chunk) do
    if :part in state().failures, do: raise("part failed")
    %{headers: [{"ETag", "etag"}]}
  end

  def complete_multipart_upload(_bucket, _key, _upload_id, _parts) do
    Agent.update(__MODULE__, &Map.update!(&1, :complete_count, fn count -> count + 1 end))
    if :complete in state().failures, do: raise("complete failed")
    %{}
  end

  def abort_multipart_upload(_bucket, _key, _upload_id) do
    Agent.update(__MODULE__, &Map.update!(&1, :abort_count, fn count -> count + 1 end))
    %{}
  end

  defp initial_state(failures) do
    %{abort_count: 0, complete_count: 0, initiate_count: 0, put_bodies: [], failures: failures}
  end
end

defmodule Minne.Adapter.S3Test do
  use ExUnit.Case, async: false

  alias Minne.Adapter.S3

  @chunk_size 5_242_880

  setup_all do
    previous_client = Application.get_env(:minne, :s3_client)
    Application.put_env(:minne, :s3_client, Minne.TestS3Client)
    on_exit(fn -> Application.put_env(:minne, :s3_client, previous_client) end)
    start_supervised!(Minne.TestS3Client)
    :ok
  end

  setup do
    Minne.TestS3Client.reset()
    :ok
  end

  test "finalizes hashes when the upload is an exact chunk multiple" do
    bytes = String.duplicate("x", @chunk_size)

    upload =
      new_upload()
      |> write(bytes)
      |> S3.close([])

    assert upload.adapter.hashes.sha256 == sha256(bytes)
    assert byte_size(upload.adapter.hashes.sha256) == 64
    assert Minne.TestS3Client.state().complete_count == 1
    assert Minne.TestS3Client.state().abort_count == 0
  end

  test "publishes a small object only on close" do
    upload = new_upload() |> write("small")

    assert Minne.TestS3Client.state().put_bodies == []
    assert Minne.TestS3Client.state().initiate_count == 0

    upload = S3.close(upload, [])
    assert Minne.TestS3Client.state().put_bodies == ["small"]
    assert upload.adapter.hashes.sha256 == sha256("small")
  end

  test "enforces max size before publishing a small object" do
    upload = new_upload(max_file_size: 4)
    assert {:error, :too_large} = S3.write_part(upload, "small", 5, false, options())
    assert Minne.TestS3Client.state().put_bodies == []
  end

  test "public abort aborts an initiated upload with no completed parts" do
    upload = new_upload() |> write(String.duplicate("x", @chunk_size))
    assert upload.adapter.upload_id == "upload-id"
    assert :ok = S3.abort(upload, [])
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "aborts the multipart upload when a part fails" do
    Minne.TestS3Client.reset([:part])
    upload = new_upload() |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "part failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().abort_count == 1
  end

  test "aborts the multipart upload when completion fails" do
    Minne.TestS3Client.reset([:complete])
    upload = new_upload() |> write(String.duplicate("x", @chunk_size))

    assert_raise RuntimeError, "complete failed", fn -> S3.close(upload, []) end
    assert Minne.TestS3Client.state().complete_count == 1
    assert Minne.TestS3Client.state().abort_count == 1
  end

  defp new_upload(overrides \\ []) do
    upload =
      %S3{}
      |> Minne.Upload.new()
      |> Map.merge(%{filename: "sample.bin", content_type: "application/octet-stream"})
      |> S3.init(Keyword.merge(options(), overrides))

    S3.start(upload, Keyword.merge(options(), overrides))
  end

  defp write(upload, bytes) do
    assert {:ok, upload} = S3.write_part(upload, bytes, byte_size(bytes), false, options())
    upload
  end

  defp options do
    [
      max_file_size: 20 * 1_024 * 1_024,
      bucket_function: fn _upload -> "bucket" end,
      path_function: fn _upload -> {"key", false} end
    ]
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
