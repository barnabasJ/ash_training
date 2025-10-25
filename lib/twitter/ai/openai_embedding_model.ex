defmodule Twitter.Ai.OpenAiEmbeddingModel do
  @moduledoc """
  OpenAI embedding model for vectorizing text.
  Uses the text-embedding-3-small model (1536 dimensions).
  """
  use AshAi.EmbeddingModel

  @impl true
  def dimensions(_opts), do: 1536

  @impl true
  def generate(texts, _opts) do
    api_key = Application.get_env(:langchain, :openai_key)

    if is_nil(api_key) do
      raise "OPENAI_API_KEY not configured"
    end

    api_key =
      if is_function(api_key, 0) do
        api_key.()
      else
        api_key
      end

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body = %{
      "input" => texts,
      "model" => "text-embedding-3-small"
    }

    case Req.post("https://api.openai.com/v1/embeddings",
           json: body,
           headers: headers
         ) do
      {:ok, %{status: 200, body: response_body}} ->
        embeddings =
          response_body["data"]
          |> Enum.sort_by(& &1["index"])
          |> Enum.map(& &1["embedding"])

        {:ok, embeddings}

      {:ok, response} ->
        {:error, "OpenAI API error: #{inspect(response)}"}

      {:error, error} ->
        {:error, "Request failed: #{inspect(error)}"}
    end
  end
end
