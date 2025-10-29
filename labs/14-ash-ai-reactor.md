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

### 2. Create Prompt Actions for RAG Pipeline

We'll create two prompt-backed actions that our Reactor will orchestrate:

1. **Query reformulation** - Converts user question into optimal search query
2. **Answer generation** - Generates answer using retrieved context

Add these actions to `lib/twitter/tweets/tweet.ex`:

```elixir
# Step 1: Reformulate user question into optimal search query
action :reformulate_query, :string do
  argument :question, :string do
    allow_nil? false
    description "The original user question"
  end

  run prompt(
    LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"}),
    prompt: """
    You are an expert at reformulating questions into effective search queries.

    User's question: <%= @input.arguments.question %>

    Generate a concise search query (2-5 keywords) that will find the most
    relevant tweets to answer this question. Return ONLY the search query,
    nothing else.

    Examples:
    Question: "What are people saying about Elixir's performance?"
    Query: "Elixir performance speed fast"

    Question: "How does Phoenix compare to Rails?"
    Query: "Phoenix Rails comparison framework"
    """
  )
end

# Step 2: Generate answer using retrieved context
action :answer_with_context, :string do
  argument :question, :string do
    allow_nil? false
    description "The question to answer"
  end

  argument :context, :string do
    allow_nil? false
    description "Pre-built context from semantic search"
  end

  run prompt(
    LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"}),
    prompt: """
    You are a helpful assistant answering questions about tweets.

    Here are some relevant tweets from our database:

    <%= @input.arguments.context %>

    User's question: <%= @input.arguments.question %>

    Please provide a helpful, concise answer based on the tweets above.
    """
  )
end
```

Update the policy to allow both actions:

```elixir
policy action([:create, :ask, :reformulate_query, :answer_with_context]) do
  authorize_if always()
end
```

### 3. Create a Reactor Module for RAG

Now create a Reactor that orchestrates the workflow by calling Ash actions.
Create `lib/twitter/ai/rag_reactor.ex`:

```elixir
defmodule Twitter.Ai.RagReactor do
  @moduledoc """
  Reactor for multi-LLM RAG workflow using Ash actions.

  Workflow:
  1. LLM reformulates user question into optimal search query
  2. Semantic search retrieves relevant tweets using reformulated query
  3. LLM generates answer using retrieved context

  All LLM calls go through Ash prompt actions, not manual API calls.
  """

  use Reactor, extensions: [Ash.Reactor]

  input :question
  input :limit, default: 5

  # Step 1: Use LLM to reformulate question into optimal search query
  action :reformulate_query, Twitter.Tweets.Tweet, :reformulate_query do
    inputs %{
      question: input(:question)
    }
  end

  # Step 2: Fetch relevant tweets using the reformulated query
  read :fetch_context_tweets, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: result(:reformulate_query)  # Use the reformulated query!
    }

    # We can add authorization context
    actor input(:actor)
  end

  # Step 3: Build context string from tweets
  step :build_context do
    argument :tweets, result(:fetch_context_tweets)

    run fn %{tweets: tweets}, _context ->
      context =
        tweets
        |> Enum.map(fn tweet -> "- \"#{tweet.text}\"" end)
        |> Enum.join("\n")

      {:ok, context}
    end
  end

  # Step 4: Use LLM to generate answer with context
  action :generate_answer, Twitter.Tweets.Tweet, :answer_with_context do
    inputs %{
      question: input(:question),
      context: result(:build_context)
    }
  end

  # Step 5: Format the final response
  step :format_response do
    argument :answer, result(:generate_answer)
    argument :tweets, result(:fetch_context_tweets)
    argument :question, input(:question)
    argument :search_query, result(:reformulate_query)

    run fn args, _context ->
      response = %{
        question: args.question,
        search_query: args.search_query,
        answer: args.answer,
        context_tweets: Enum.map(args.tweets, & &1.text),
        context_count: length(args.tweets)
      }

      {:ok, response}
    end
  end

  # Return the formatted response
  return :format_response
end
```

Key improvements:

- **Multi-LLM workflow**: Query reformulation → Retrieval → Answer generation
- Uses `action` step for prompt-backed actions (reformulate_query,
  answer_with_context)
- Uses `read` step for semantic search
- No manual API calls - everything goes through Ash actions
- Shows how one LLM's output (`reformulate_query`) feeds into retrieval step
- Response includes the reformulated query for transparency
- Authorization context can be passed via `actor`

### 4. Add a Reactor-Based Action to Tweet

Add a generic action to Tweet that uses the Reactor directly. Ash automatically
handles running the Reactor when you pass the module to `run`.

Add to `lib/twitter/tweets/tweet.ex`:

```elixir
action :ask_with_reactor, :map do
  argument :question, :string, allow_nil?: false
  argument :limit, :integer, default: 5

  # Pass the Reactor module directly - Ash handles execution automatically
  run Twitter.Ai.RagReactor
end
```

Update the policy:

```elixir
policy action([:create, :ask, :reformulate_query, :answer_with_context, :ask_with_reactor]) do
  authorize_if always()
end
```

**Key insight**: You don't need to manually call `Reactor.run/4`. Just pass the
Reactor module to `run` and Ash:

- Automatically maps action arguments to Reactor inputs
- Passes the action context into the Reactor's context
- Handles the Reactor execution lifecycle

### 5. Add Compensating Actions

One of Reactor's powerful features is automatic rollback. Let's add compensation
to the LLM action step in case something fails downstream.

Update the `:generate_answer` action step in `lib/twitter/ai/rag_reactor.ex`:

```elixir
# Step 3: Call the prompt action with context and compensation
action :generate_answer, Twitter.Tweets.Tweet, :answer_with_context do
  inputs %{
    question: input(:question),
    context: result(:build_context)
  }

  # If something fails after this, log the rollback
  compensate fn _value, _context ->
    require Logger
    Logger.info("Compensating LLM call - workflow rolled back")
    :ok
  end
end
```

### 6. Add Error Handling and Retry Logic

Reactor supports automatic retries. Let's add retry logic to the action step:

```elixir
action :generate_answer, Twitter.Tweets.Tweet, :answer_with_context do
  inputs %{
    question: input(:question),
    context: result(:build_context)
  }

  # Retry up to 3 times on failure
  max_retries 3

  compensate fn _value, _context ->
    require Logger
    Logger.warn("LLM call failed after retries - compensating")
    :ok
  end
end
```

### 7. Test the Reactor-Based RAG

Test the new Reactor-based action in IEx:

```elixir
# Compare with the simple action from Lab 13
simple_result = Twitter.Tweets.Tweet
|> Ash.ActionInput.for_action(:ask, %{question: "What are people saying about Elixir?"})
|> Ash.run_action!()

IO.puts("Simple action result:")
IO.puts(simple_result)

# Now try the Reactor-based approach with query reformulation
reactor_result = Twitter.Tweets.Tweet
|> Ash.ActionInput.for_action(:ask_with_reactor, %{
  question: "What are people saying about Elixir?",
  limit: 5
})
|> Ash.run_action!()

IO.puts("\nReactor-based result:")
IO.inspect(reactor_result)

# Output will include the reformulated search query:
# %{
#   question: "What are people saying about Elixir?",
#   search_query: "Elixir programming language features benefits",
#   answer: "Based on the tweets...",
#   context_tweets: [...],
#   context_count: 5
# }
```

Notice how the Reactor result includes `:search_query` showing how the LLM
reformulated the question for better semantic search results.

### 8. Add Parallel Processing (Optional)

One advantage of Reactor is concurrent execution. Let's demonstrate how you
could fetch multiple data sources in parallel:

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

### 9. Add Telemetry

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

### 10. Create a Nested Reactor

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

### 11. Compare Performance

Let's compare the simple action approach vs Reactor. Create a simple benchmark:

```elixir
# In IEx
question = "What are the benefits of functional programming?"

# Time the simple :ask action from Lab 13
{time1, _} = :timer.tc(fn ->
  Twitter.Tweets.Tweet
  |> Ash.ActionInput.for_action(:ask, %{question: question})
  |> Ash.run_action!()
end)

# Time the Reactor-based approach
{time2, _} = :timer.tc(fn ->
  Twitter.Tweets.Tweet
  |> Ash.ActionInput.for_action(:ask_with_reactor, %{question: question})
  |> Ash.run_action!()
end)

IO.puts("Simple action: #{time1 / 1_000_000}s")
IO.puts("Reactor: #{time2 / 1_000_000}s")
```

Note: The Reactor approach may have slightly more overhead for this simple case,
but it provides better structure for complex workflows with parallel steps and
error handling.

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

## Reactor vs Simple Action: Key Differences

| Aspect             | Simple Action (Lab 13)   | Reactor (Lab 14)            |
| ------------------ | ------------------------ | --------------------------- |
| **Execution**      | Sequential               | Concurrent where possible   |
| **Error Handling** | Built into Ash actions   | Automatic with compensation |
| **Testing**        | Test entire action       | Test individual steps       |
| **Observability**  | Ash action telemetry     | Reactor-specific telemetry  |
| **Complexity**     | Simple workflows         | Complex workflows           |
| **Reusability**    | Action-specific          | Composable reactors         |
| **Rollback**       | Ash transaction rollback | Saga pattern compensation   |
| **API Calls**      | Integrated via Ash       | Orchestrates Ash actions    |

## When to Use Each Approach

**Use simple actions with prepare hooks (Lab 13) when:**

- Workflow is simple and linear
- All operations fit within a single action
- Standard Ash error handling is sufficient
- Quick prototyping

**Use Reactor (Lab 14) when:**

- Complex multi-step workflows with dependencies
- Need parallel execution of independent steps
- Require granular compensation/rollback
- Building reusable workflow components
- Need detailed step-level observability
- Orchestrating across multiple resources
