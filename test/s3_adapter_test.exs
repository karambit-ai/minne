defmodule Minne.TestS3Client do
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  end

  def start_link do
    Agent.start_link(fn -> %{abort_count: 0, complete_count: 0, failures: []} end,
      name: __MODULE__
    )
  end

  def reset(failures \\ []) do
    Agent.update(__MODULE__, fn _ -> %{abort_count: 0, complete_count: 0, failures: failures} end)
  end

  def state, do: Agent.get(__MODULE__, & &1)

  def put_object(_bucket, _key, _body), do: %{}
  def initiate_multipart_upload(_bucket, _key), do: %{body: %{upload_id: "upload-id"}}

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
end

defmodule Minne.Adapter.S3Test do
  use ExUnit.Case, async: false

  alias Minne.Adapter.S3

  @chunk_size 5_242_880

  setup_all do
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

  defp new_upload do
    upload =
      %S3{}
      |> Minne.Upload.new()
      |> Map.merge(%{filename: "sample.bin", content_type: "application/octet-stream"})
      |> S3.init(options())

    S3.start(upload, options())
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
