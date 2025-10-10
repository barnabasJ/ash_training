# Lab 13 - Vectorization & RAG with Actions

## Relevant Documentation

- [AshAi Vectorization Guide](https://hexdocs.pm/ash_ai/vectorization.html)
- [PostgreSQL pgvector Extension](https://github.com/pgvector/pgvector)
- [AshPostgres Vector Support](https://hexdocs.pm/ash_postgres/AshPostgres.Extensions.Vector.html)
- [Prompt-backed Actions](https://hexdocs.pm/ash_ai/prompt-backed-actions.html)
- [Action Hooks](https://hexdocs.pm/ash/actions.html#module-action-hooks)

## Context

Retrieval-Augmented Generation (RAG) is a technique that enhances LLM responses
by providing relevant context from your data. The process involves:

1. **Vectorization** - Converting text into numerical embeddings that capture
   semantic meaning
2. **Storage** - Saving these embeddings alongside your data using pgvector
3. **Retrieval** - Finding semantically similar content using vector distance
   calculations
4. **Augmentation** - Injecting retrieved context into LLM prompts for better
   responses

In this lab, we'll implement RAG using AshAi's vectorization features and action
hooks. We'll make tweets searchable by semantic meaning, not just keywords, and
create an AI action that uses relevant tweets as context.

## Steps

### 1. Enable pgvector Extension

First, we need to enable PostgreSQL's vector extension. Create a migration:

```bash
mix ecto.gen.migration enable_pgvector
```

Edit the generated migration file in `priv/repo/migrations/` and add:

```elixir
defmodule Twitter.Repo.Migrations.EnablePgvector do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS vector")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS vector")
  end
end
```

Run the migration:

```bash
mix ecto.migrate
```

### 2. Create an Embedding Model Module

We need to configure how text gets converted to embeddings. Create a new file
`lib/twitter/ai/openai_embedding_model.ex`:

```elixir
defmodule Twitter.Ai.OpenAiEmbeddingModel do
  @moduledoc """
  OpenAI embedding model for vectorizing text.
  Uses the text-embedding-3-small model.
  """

  def embed(text) when is_binary(text) do
    embed([text])
  end

  def embed(texts) when is_list(texts) do
    api_key = Application.get_env(:langchain, :openai_key)

    if is_nil(api_key) do
      raise "OPENAI_API_KEY not configured"
    end

    payload = %{
      input: texts,
      model: "text-embedding-3-small"
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post("https://api.openai.com/v1/embeddings",
           json: payload,
           headers: headers
         ) do
      {:ok, %{status: 200, body: body}} ->
        embeddings =
          body["data"]
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
```

Add `req` to your dependencies in `mix.exs`:

```elixir
{:req, "~> 0.4"}
```

Then run:

```bash
mix deps.get
```

### 3. Add Vectorization to Tweet Resource

Now we'll configure the Tweet resource to automatically vectorize its content.
Open `lib/twitter/tweets/tweet.ex` and add the vectorization configuration:

```elixir
defmodule Twitter.Tweets.Tweet do
  use Ash.Resource,
    domain: Twitter.Tweets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [
      AshGraphql.Resource,
      AshJsonApi.Resource,
      AshAi.Resource  # Add this extension
    ]

  # ... existing code ...

  # Add this vectorize block
  vectorize do
    # Vectorize the full content of the tweet
    full_text do
      text fn tweet ->
        """
        Tweet: #{tweet.text}
        """
      end
    end

    # Store embeddings in this attribute (will be auto-created)
    attributes(full_text: :full_text_vector)

    # Use our OpenAI embedding model
    embedding_model Twitter.Ai.OpenAiEmbeddingModel

    # Use after_action strategy for immediate updates
    strategy :after_action
  end

  # ... rest of existing code ...
end
```

### 4. Generate and Run Migrations

The vectorization configuration needs to add a vector column to the tweets
table:

```bash
mix ash.codegen add_tweet_vectors
mix ash.migrate
```

This creates a new column `full_text_vector` of type `vector(1536)` (the
dimension of OpenAI's text-embedding-3-small model).

### 5. Test Vectorization

Start an IEx session and create a tweet to see vectorization in action:

```bash
iex -S mix
```

```elixir
# Create a tweet
tweet = Twitter.Tweets.Tweet
|> Ash.Changeset.for_create(:create, %{text: "Elixir is an amazing functional programming language"})
|> Ash.create!(actor: user)

# Check that the vector was created (you'll see a long array of floats)
tweet.full_text_vector
```

### 6. Create a Semantic Search Action

Add a read action that can search tweets by semantic similarity. In
`lib/twitter/tweets/tweet.ex`:

```elixir
actions do
  # ... existing actions ...

  read :semantic_search do
    argument :query, :string, allow_nil?: false

    prepare fn query, _context ->
      search_text = Ash.Changeset.get_argument(query, :query)

      # Get embedding for the search query
      {:ok, [embedding]} = Twitter.Ai.OpenAiEmbeddingModel.embed(search_text)

      # Sort by vector similarity
      query
      |> Ash.Query.sort(
        vector_cosine_distance: {
          :full_text_vector,
          embedding
        }
      )
      |> Ash.Query.limit(10)
    end
  end
end
```

Add the vector distance function support to the postgres config:

```elixir
postgres do
  repo Twitter.Repo
  table "tweets"

  custom_indexes do
    # Add a vector index for faster similarity searches
    index [:full_text_vector],
      using: "hnsw",
      with: "m = 16, ef_construction = 64",
      concurrently: false
  end
end
```

Generate and run migrations:

```bash
mix ash.codegen add_vector_index
mix ash.migrate
```

### 7. Test Semantic Search

In IEx, try searching:

```elixir
# Search for tweets about programming
Twitter.Tweets.Tweet
|> Ash.Query.for_read(:semantic_search, %{query: "functional programming languages"})
|> Ash.read!()
```

This should return tweets semantically similar to the query, not just keyword
matches.

### 8. Create a RAG-Enabled Prompt Action

Now we'll create a generic action that uses vectorization to retrieve relevant
tweets and uses them as context for an LLM. Create a new resource for AI
queries:

```bash
mix ash.gen.resource Twitter.Ai.Query \
  --default-actions read,create
```

Open `lib/twitter/ai/query.ex` and configure it as a prompt-backed action:

```elixir
defmodule Twitter.Ai.Query do
  use Ash.Resource,
    domain: Twitter.Ai,
    extensions: [AshAi.Resource]

  attributes do
    uuid_primary_key :id

    attribute :question, :string, allow_nil?: false, public?: true
    attribute :answer, :string, allow_nil?: false, public?: true
    attribute :context_tweets, {:array, :string}, public?: true

    timestamps()
  end

  actions do
    defaults [:read]

    create :ask do
      accept [:question]

      # Use a before_action hook to fetch context
      change before_action(fn changeset, _context ->
        question = Ash.Changeset.get_attribute(changeset, :question)

        # Get relevant tweets using semantic search
        context_tweets =
          Twitter.Tweets.Tweet
          |> Ash.Query.for_read(:semantic_search, %{query: question})
          |> Ash.Query.limit(3)
          |> Ash.read!()

        # Store tweet texts for context
        tweet_texts = Enum.map(context_tweets, & &1.text)

        changeset
        |> Ash.Changeset.change_attribute(:context_tweets, tweet_texts)
      end)

      # Use the LLM to generate an answer
      change AshAi.Change.PromptCompletion.new(
        prompt: fn query ->
          context = Enum.join(query.context_tweets, "\n- ")

          """
          You are a helpful assistant answering questions about tweets.

          Here are some relevant tweets for context:
          - #{context}

          Question: #{query.question}

          Provide a helpful answer based on the tweets above.
          """
        end,
        output_attribute: :answer,
        model: "gpt-4-turbo-preview"
      )
    end
  end
end
```

### 9. Register the Query Resource

Add the Query resource to the `Twitter.Ai` domain in `lib/twitter/ai.ex`:

```elixir
defmodule Twitter.Ai do
  use Ash.Domain

  resources do
    resource Twitter.Ai.Conversation
    resource Twitter.Ai.Message
    resource Twitter.Ai.Query  # Add this line
  end
end
```

### 10. Test RAG Query

Generate migrations and test:

```bash
mix ash.codegen add_ai_query
mix ash.migrate
```

In IEx:

```elixir
# First create some tweets with different topics
user = # ... get or create a user ...

Twitter.Tweets.Tweet
|> Ash.Changeset.for_create(:create, %{text: "Elixir's GenServers make concurrent programming easy"})
|> Ash.create!(actor: user)

Twitter.Tweets.Tweet
|> Ash.Changeset.for_create(:create, %{text: "Phoenix LiveView enables real-time features without JavaScript"})
|> Ash.create!(actor: user)

# Now ask a question
query = Twitter.Ai.Query
|> Ash.Changeset.for_create(:ask, %{question: "What are some features of Elixir and Phoenix?"})
|> Ash.create!()

# See the answer
IO.puts(query.answer)

# See which tweets were used as context
IO.inspect(query.context_tweets)
```

### 11. Add Code Interface

Add a code interface to make querying easier. In `lib/twitter/ai.ex`:

```elixir
resources do
  resource Twitter.Ai.Query do
    define :ask, action: :ask, args: [:question]
  end
end
```

Now you can use:

```elixir
Twitter.Ai.ask("What are people tweeting about Elixir?")
```

## Try on your own

- Add vectorization to user bios and search users by semantic similarity

- Implement multiple vectorization strategies (`:after_action` vs `:ash_oban`)
  and compare performance

- Create a `regenerate_embeddings` action to re-vectorize all existing tweets

- Add more sophisticated context retrieval (e.g., filter by date, user, or like
  count)

- Combine vector search with traditional filters (e.g., semantic search within
  tweets from the last week)

- Experiment with different embedding models (e.g., `text-embedding-3-large` for
  higher quality)

- Add a `relevance_score` to show how similar each context tweet is to the query

- Implement a chat interface that uses RAG to answer questions about tweets

## Verification

To verify your implementation:

1. **Vectorization**: Create a tweet and confirm `full_text_vector` is populated
2. **Semantic Search**: Search for concepts (not exact keywords) and get
   relevant results
3. **RAG Query**: Ask a question and verify the answer uses tweet context
4. **Context Tweets**: Check that the `context_tweets` attribute contains
   relevant tweets
5. **Index Performance**: Query the database to confirm the HNSW index exists

## Understanding the Vectorization Strategy

AshAi supports three vectorization strategies:

- **`:after_action`** (used in this lab) - Synchronous, updates happen
  immediately in the same transaction. Best for: small datasets, real-time
  requirements
- **`:ash_oban`** - Asynchronous, updates happen in background jobs. Best for:
  large datasets, bulk operations
- **`:manual`** - No automatic updates, you control when to vectorize. Best for:
  custom workflows, optimization

For this training app, `:after_action` is perfect. For production apps with
millions of records, consider `:ash_oban`.
