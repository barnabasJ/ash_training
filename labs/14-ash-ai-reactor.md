# Lab 14 - RAG with Reactor

## Relevant Documentation

- [Reactor Documentation](https://hexdocs.pm/reactor)
- [Ash Reactor Extension](https://hexdocs.pm/ash/reactor.html)
- [Reactor in the Elixir Ecosystem](https://hexdocs.pm/reactor/ecosystem.html)
- [Generic Actions](https://hexdocs.pm/ash/generic-actions.html)
- [Ash Reactor Steps](https://hexdocs.pm/ash/Ash.Reactor.html)

## Context

In Lab 13, we implemented RAG using a `before_action` hook to fetch context and
inject it into a prompt. This approach works well for simple workflows, but has
limitations:

- **Sequential Execution** - Each step waits for the previous one
- **Limited Error Handling** - No automatic rollback or compensation
- **No Concurrency** - Can't parallelize independent operations
- **Difficult Testing** - Hard to test individual steps in isolation

**Reactor** is Elixir's solution for orchestrating complex workflows with:

- **Concurrent Execution** - Run independent steps in parallel
- **Automatic Rollbacks** - Saga pattern with compensating actions
- **Error Recovery** - Retry logic and graceful degradation
- **Composability** - Reactors can call other reactors

In this lab, we'll rebuild our RAG implementation using Reactor to gain these
benefits and demonstrate more sophisticated workflow orchestration.

## Steps

### 1. Add Reactor Dependencies

Reactor should already be installed as a dependency of Ash, but let's ensure we
have the Ash.Reactor extension available. In `mix.exs`, verify you have:

```elixir
{:ash, "~> 3.0"}
{:reactor, "~> 0.9"}  # Usually included via ash
```

Run `mix deps.get` if needed.

### 2. Create a Reactor Module for RAG

Create a new file `lib/twitter/ai/rag_reactor.ex`:

```elixir
defmodule Twitter.Ai.RagReactor do
  @moduledoc """
  Reactor for RAG workflow: vectorize query -> fetch context -> build prompt -> call LLM
  """

  use Reactor, extensions: [Ash.Reactor]

  input :question
  input :actor

  # Step 1: Vectorize the user's question
  step :vectorize_query do
    argument :question, input(:question)

    run fn %{question: question}, _context ->
      Twitter.Ai.OpenAiEmbeddingModel.embed(question)
    end
  end

  # Step 2: Fetch relevant tweets using vector similarity
  step :fetch_context_tweets do
    argument :question, input(:question)

    run fn %{question: question}, _context ->
      tweets =
        Twitter.Tweets.Tweet
        |> Ash.Query.for_read(:semantic_search, %{query: question})
        |> Ash.Query.limit(5)
        |> Ash.read!()

      {:ok, tweets}
    end
  end

  # Step 3: Extract tweet texts for context
  step :extract_tweet_texts do
    argument :tweets, result(:fetch_context_tweets)

    run fn %{tweets: tweets}, _context ->
      texts = Enum.map(tweets, & &1.text)
      {:ok, texts}
    end
  end

  # Step 4: Build the prompt with context
  step :build_prompt do
    argument :question, input(:question)
    argument :context_tweets, result(:extract_tweet_texts)

    run fn %{question: question, context_tweets: context_tweets}, _context ->
      context = Enum.join(context_tweets, "\n- ")

      prompt = """
      You are a helpful assistant answering questions about tweets.

      Here are some relevant tweets for context:
      - #{context}

      Question: #{question}

      Provide a helpful answer based on the tweets above. Be concise and specific.
      """

      {:ok, prompt}
    end
  end

  # Step 5: Call the LLM
  step :call_llm do
    argument :prompt, result(:build_prompt)

    run fn %{prompt: prompt}, _context ->
      # Use LangChain or direct API call
      call_openai_chat(prompt)
    end
  end

  # Step 6: Format the final response
  step :format_response do
    argument :answer, result(:call_llm)
    argument :context_tweets, result(:extract_tweet_texts)
    argument :question, input(:question)

    run fn %{answer: answer, context_tweets: context_tweets, question: question}, _context ->
      response = %{
        question: question,
        answer: answer,
        context_tweets: context_tweets,
        context_count: length(context_tweets)
      }

      {:ok, response}
    end
  end

  # Return the formatted response
  return :format_response

  # Helper function to call OpenAI
  defp call_openai_chat(prompt) do
    api_key = Application.get_env(:langchain, :openai_key)

    payload = %{
      model: "gpt-4-turbo-preview",
      messages: [
        %{role: "user", content: prompt}
      ],
      temperature: 0.7
    }

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    case Req.post("https://api.openai.com/v1/chat/completions",
           json: payload,
           headers: headers
         ) do
      {:ok, %{status: 200, body: body}} ->
        answer = get_in(body, ["choices", Access.at(0), "message", "content"])
        {:ok, answer}

      {:ok, response} ->
        {:error, "OpenAI API error: #{inspect(response)}"}

      {:error, error} ->
        {:error, "Request failed: #{inspect(error)}"}
    end
  end
end
```

### 3. Create a Generic Action Using Reactor

Now we'll create a generic action that uses this Reactor. Update
`lib/twitter/ai/query.ex`:

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
    attribute :context_count, :integer, public?: true

    timestamps()
  end

  actions do
    defaults [:read]

    # The old before_action approach from Lab 13
    create :ask do
      accept [:question]

      change before_action(fn changeset, _context ->
        # ... existing implementation ...
      end)

      change AshAi.Change.PromptCompletion.new(
        # ... existing implementation ...
      )
    end

    # New Reactor-based approach
    action :ask_with_reactor, :map do
      argument :question, :string, allow_nil?: false

      run fn input, context ->
        # Run the Reactor
        case Reactor.run(Twitter.Ai.RagReactor, %{
               question: input.question,
               actor: context[:actor]
             }) do
          {:ok, result} ->
            {:ok, result}

          {:error, error} ->
            {:error, error}
        end
      end
    end

    # Alternative: Create action using Reactor
    create :ask_and_persist do
      accept [:question]

      # Use Reactor as the implementation
      run Twitter.Ai.RagReactor

      # After Reactor succeeds, store the results
      change fn changeset, context ->
        case context[:reactor_result] do
          %{answer: answer, context_tweets: tweets, context_count: count} ->
            changeset
            |> Ash.Changeset.change_attribute(:answer, answer)
            |> Ash.Changeset.change_attribute(:context_tweets, tweets)
            |> Ash.Changeset.change_attribute(:context_count, count)

          _ ->
            changeset
        end
      end
    end
  end
end
```

### 4. Add Compensating Actions

One of Reactor's powerful features is automatic rollback. Let's add compensation
for our LLM call in case something fails downstream:

Update `lib/twitter/ai/rag_reactor.ex`:

```elixir
# Step 5: Call the LLM with compensation
step :call_llm do
  argument :prompt, result(:build_prompt)

  run fn %{prompt: prompt}, _context ->
    call_openai_chat(prompt)
  end

  # If something fails after this, we can log or clean up
  compensate fn _value, _context ->
    # Log that we made an LLM call that was rolled back
    require Logger
    Logger.info("Compensating LLM call - workflow rolled back")
    :ok
  end
end
```

### 5. Add Error Handling and Retry Logic

Reactor supports automatic retries. Let's add retry logic for the LLM call:

```elixir
step :call_llm do
  argument :prompt, result(:build_prompt)

  # Retry up to 3 times with exponential backoff
  max_retries 3

  run fn %{prompt: prompt}, context ->
    attempt = Map.get(context, :attempt, 1)

    case call_openai_chat(prompt) do
      {:ok, answer} ->
        {:ok, answer}

      {:error, reason} ->
        if attempt < 3 do
          # Exponential backoff: 1s, 2s, 4s
          :timer.sleep(:timer.seconds(:math.pow(2, attempt - 1)))
          {:retry, reason}
        else
          {:error, reason}
        end
    end
  end

  compensate fn _value, _context ->
    require Logger
    Logger.info("Compensating LLM call - workflow rolled back")
    :ok
  end
end
```

### 6. Test the Reactor-Based RAG

In IEx, test the new implementation:

```elixir
# Using the generic action
result = Twitter.Ai.Query
|> Ash.ActionInput.for_action(:ask_with_reactor, %{question: "What are people saying about Elixir?"})
|> Ash.run_action!()

IO.inspect(result)

# Or persist the result
query = Twitter.Ai.Query
|> Ash.Changeset.for_create(:ask_and_persist, %{
  question: "Tell me about Phoenix LiveView based on the tweets"
})
|> Ash.create!()

IO.puts(query.answer)
```

### 7. Add Parallel Processing

One advantage of Reactor is concurrent execution. Let's fetch tweets and
vectorize the query in parallel:

```elixir
# These steps can run concurrently since they don't depend on each other
step :vectorize_query do
  argument :question, input(:question)

  async? true  # Mark as safe for concurrent execution

  run fn %{question: question}, _context ->
    Twitter.Ai.OpenAiEmbeddingModel.embed(question)
  end
end

step :fetch_recent_tweets do
  # Fetch recent tweets independently
  async? true  # Can run in parallel with vectorize_query

  run fn _args, _context ->
    tweets =
      Twitter.Tweets.Tweet
      |> Ash.Query.for_read(:feed)
      |> Ash.Query.limit(10)
      |> Ash.read!()

    {:ok, tweets}
  end
end

# Later steps wait for both to complete
step :combine_context do
  argument :query_vector, result(:vectorize_query)
  argument :recent_tweets, result(:fetch_recent_tweets)
  argument :question, input(:question)

  run fn args, _context ->
    # Now we have both the vector and recent tweets
    # We can do more sophisticated context building
    {:ok, args}
  end
end
```

### 8. Add Telemetry

Reactor emits telemetry events. Let's add monitoring:

Create `lib/twitter/ai/reactor_telemetry.ex`:

```elixir
defmodule Twitter.Ai.ReactorTelemetry do
  require Logger

  def setup do
    :telemetry.attach_many(
      "reactor-handler",
      [
        [:reactor, :run, :start],
        [:reactor, :run, :stop],
        [:reactor, :step, :start],
        [:reactor, :step, :stop],
        [:reactor, :step, :error]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:reactor, :run, :start], _measurements, metadata, _config) do
    Logger.info("Reactor starting: #{inspect(metadata.reactor)}")
  end

  def handle_event([:reactor, :run, :stop], measurements, metadata, _config) do
    Logger.info(
      "Reactor completed: #{inspect(metadata.reactor)} in #{measurements.duration}µs"
    )
  end

  def handle_event([:reactor, :step, :start], _measurements, metadata, _config) do
    Logger.debug("Step starting: #{metadata.step}")
  end

  def handle_event([:reactor, :step, :stop], measurements, metadata, _config) do
    Logger.debug("Step completed: #{metadata.step} in #{measurements.duration}µs")
  end

  def handle_event([:reactor, :step, :error], _measurements, metadata, _config) do
    Logger.error(
      "Step error: #{metadata.step} - #{inspect(metadata.error)}"
    )
  end
end
```

Add to your Application module:

```elixir
# In lib/twitter/application.ex
def start(_type, _args) do
  # Set up Reactor telemetry
  Twitter.Ai.ReactorTelemetry.setup()

  # ... rest of application start
end
```

### 9. Create a Nested Reactor

Reactors can be composed. Let's create a sub-reactor for context fetching:

```elixir
defmodule Twitter.Ai.ContextFetcherReactor do
  use Reactor

  input :question
  input :limit

  step :vectorize do
    argument :question, input(:question)
    run fn %{question: q}, _ ->
      Twitter.Ai.OpenAiEmbeddingModel.embed(q)
    end
  end

  step :search_tweets do
    argument :question, input(:question)
    argument :limit, input(:limit)

    run fn %{question: q, limit: limit}, _ ->
      tweets =
        Twitter.Tweets.Tweet
        |> Ash.Query.for_read(:semantic_search, %{query: q})
        |> Ash.Query.limit(limit)
        |> Ash.read!()

      {:ok, tweets}
    end
  end

  return :search_tweets
end

# Use it in the main reactor
defmodule Twitter.Ai.RagReactor do
  # ... existing code ...

  # Replace the fetch_context_tweets step with:
  step :fetch_context do
    argument :question, input(:question)

    compose Twitter.Ai.ContextFetcherReactor do
      argument :question, input(:question)
      argument :limit, value(5)
    end
  end
end
```

### 10. Compare Performance

Let's compare the before_action approach vs Reactor. Create a simple benchmark:

```elixir
# In IEx
question = "What are the benefits of functional programming?"

# Time the before_action approach
{time1, _} = :timer.tc(fn ->
  Twitter.Ai.Query
  |> Ash.Changeset.for_create(:ask, %{question: question})
  |> Ash.create!()
end)

# Time the Reactor approach
{time2, _} = :timer.tc(fn ->
  Twitter.Ai.Query
  |> Ash.ActionInput.for_action(:ask_with_reactor, %{question: question})
  |> Ash.run_action!()
end)

IO.puts("Before action: #{time1 / 1_000_000}s")
IO.puts("Reactor: #{time2 / 1_000_000}s")
```

## Try on your own

- Add a caching layer to avoid re-embedding the same question

- Create a Reactor that processes multiple questions in parallel

- Implement a "conversation" reactor that maintains context across multiple
  turns

- Add dynamic step selection based on input (e.g., skip vectorization if query
  is very short)

- Create a reactor that tries multiple LLM providers and uses the fastest
  response

- Implement a "critique and refine" pattern where one LLM critiques another's
  response

- Add persistence checkpoints so reactors can resume after failures

- Create metrics to track which steps are slowest in your RAG pipeline

## Verification

To verify your Reactor implementation:

1. **Basic Execution**: Confirm the Reactor runs and returns expected results
2. **Telemetry**: Check logs to see step execution order and timings
3. **Error Handling**: Trigger an error and verify compensation runs
4. **Concurrency**: Verify async steps run in parallel (check telemetry
   timestamps)
5. **Composition**: Test the nested reactor executes correctly

## Reactor vs Before Action: Key Differences

| Aspect             | Before Action (Lab 13) | Reactor (Lab 14)            |
| ------------------ | ---------------------- | --------------------------- |
| **Execution**      | Sequential             | Concurrent where possible   |
| **Error Handling** | Manual try/catch       | Automatic with compensation |
| **Testing**        | Test entire action     | Test individual steps       |
| **Observability**  | Custom logging         | Built-in telemetry          |
| **Complexity**     | Simple workflows       | Complex workflows           |
| **Reusability**    | Hard to reuse parts    | Composable reactors         |
| **Rollback**       | Manual cleanup         | Automatic saga pattern      |

## When to Use Each Approach

**Use before_action/after_action when:**

- Workflow is simple and linear
- No need for parallelization
- Minimal error recovery needed
- Quick prototyping

**Use Reactor when:**

- Complex multi-step workflows
- Need parallel execution
- Require automatic rollback
- Building reusable workflows
- Need detailed observability
- Error recovery is critical
