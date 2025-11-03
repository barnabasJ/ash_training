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
- **Single Query Limitation** - Only one search query limits result diversity

**Reactor** is Elixir's solution for orchestrating complex workflows with:

- **Concurrent Execution** - Run independent steps in parallel
- **Automatic Rollbacks** - Saga pattern with compensating actions
- **Error Recovery** - Retry logic and graceful degradation
- **Composability** - Reactors can call other reactors

In this lab, we'll rebuild our RAG implementation using Reactor to:
1. Generate multiple diverse search queries from a single user question
2. Fetch tweets for each query in parallel
3. Deduplicate results across all queries
4. Rank tweets by relevance
5. Limit to the most relevant tweets

This showcases Reactor's parallel execution, data transformation pipelines, and
sophisticated workflow orchestration capabilities.

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

We'll create three prompt-backed actions that our Reactor will orchestrate:

1. **Query reformulation** - Converts user question into optimal search query
2. **Multiple query generation** - Generates diverse search queries for broader coverage
3. **Answer generation** - Generates answer using retrieved context

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

# Step 1b: Generate multiple diverse search queries for parallel fetching
action :generate_search_queries, {:array, :string} do
  argument :question, :string do
    allow_nil? false
    description "The original user question"
  end

  argument :num_queries, :integer do
    default 3
    description "Number of diverse search queries to generate"
  end

  run fn input, _context ->
    question = input.arguments.question
    num_queries = input.arguments.num_queries

    result =
      LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"})
      |> LangChain.Chains.LLMChain.new!()
      |> LangChain.Chains.LLMChain.add_message!(
        LangChain.Message.new_user!("""
        You are an expert at generating diverse search queries.

        User's question: #{question}

        Generate #{num_queries} different search queries that approach this question from different angles.
        Each query should be 2-5 keywords that capture different aspects or perspectives.
        Return the queries as a JSON array of strings, nothing else.

        Example output format:
        ["query one", "query two", "query three"]

        Focus on diversity to maximize coverage of relevant tweets.
        """)
      )
      |> LangChain.Chains.LLMChain.run()

    case result do
      {:ok, _updated_chain, response} ->
        content = response.content |> String.trim()

        case Jason.decode(content) do
          {:ok, queries} when is_list(queries) -> {:ok, queries}
          _ -> {:ok, [question]}  # Fallback
        end

      {:error, error} ->
        {:error, error}
    end
  end
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

Update the policy to allow all actions:

```elixir
policy action([
  :create, :ask, :reformulate_query, 
  :generate_search_queries, :answer_with_context, :ask_with_reactor
]) do
  authorize_if always()
end
```

### 3. Create an Enhanced Reactor Module for Parallel Multi-Query RAG

Now create a Reactor that demonstrates parallel execution, deduplication, ranking, and limiting.
Update `lib/twitter/ai/rag_reactor.ex`:

```elixir
defmodule Twitter.Ai.RagReactor do
  @moduledoc """
  Enhanced Reactor for multi-query parallel RAG workflow using Ash actions.

  Workflow:
  1. LLM generates multiple diverse search queries from user question
  2. Parallel semantic searches retrieve tweets for each query
  3. Deduplicate tweets across all results
  4. Rank tweets by relevance score
  5. Limit to top N tweets
  6. Build context and LLM generates answer

  This showcases Reactor's parallel execution, data transformation pipelines,
  and workflow orchestration capabilities.
  """

  use Reactor, extensions: [Ash.Reactor]

  input :question
  input :limit

  # Step 1: Generate multiple diverse search queries using LLM
  action :generate_queries, Twitter.Tweets.Tweet, :generate_search_queries do
    inputs %{
      question: input(:question),
      num_queries: value(3)
    }
  end

  # Step 2-4: Fetch tweets for each query IN PARALLEL
  # These three steps will run concurrently once generate_queries completes
  read :fetch_tweets_1, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: template("{{ queries[0] }}", queries: result(:generate_queries))
    }
    wait_for [:generate_queries]
  end

  read :fetch_tweets_2, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: template("{{ queries[1] }}", queries: result(:generate_queries))
    }
    wait_for [:generate_queries]
  end

  read :fetch_tweets_3, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: template("{{ queries[2] }}", queries: result(:generate_queries))
    }
    wait_for [:generate_queries]
  end

  # Step 5: Deduplicate tweets across all fetch results
  step :deduplicate_tweets do
    argument :tweets_1, result(:fetch_tweets_1)
    argument :tweets_2, result(:fetch_tweets_2)
    argument :tweets_3, result(:fetch_tweets_3)

    run fn args, _context ->
      all_tweets = args.tweets_1 ++ args.tweets_2 ++ args.tweets_3
      
      # Deduplicate by tweet ID
      unique_tweets = Enum.uniq_by(all_tweets, & &1.id)
      
      {:ok, unique_tweets}
    end
  end

  # Step 6: Rank tweets by calculating relevance scores
  step :rank_tweets do
    argument :tweets, result(:deduplicate_tweets)
    argument :question, input(:question)

    run fn args, _context ->
      # Generate embedding for the original question
      case Twitter.Ai.OpenAiEmbeddingModel.generate([args.question], []) do
        {:ok, [question_vector]} ->
          # Calculate cosine similarity for each tweet
          tweets_with_scores =
            args.tweets
            |> Enum.map(fn tweet ->
              score =
                if tweet.full_text_vector do
                  1.0 - cosine_distance(question_vector, tweet.full_text_vector)
                else
                  0.0
                end

              {tweet, score}
            end)
            |> Enum.sort_by(fn {_tweet, score} -> score end, :desc)

          {:ok, tweets_with_scores}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  # Step 7: Limit to top N tweets
  step :limit_tweets do
    argument :ranked_tweets, result(:rank_tweets)
    argument :limit, input(:limit)

    run fn args, _context ->
      top_tweets =
        args.ranked_tweets
        |> Enum.take(args.limit)
        |> Enum.map(fn {tweet, _score} -> tweet end)

      {:ok, top_tweets}
    end
  end

  # Step 8: Build context string from limited tweets
  step :build_context do
    argument :tweets, result(:limit_tweets)

    run fn %{tweets: tweets}, _context ->
      context =
        tweets
        |> Enum.map(fn tweet -> "- \"#{tweet.text}\"" end)
        |> Enum.join("\n")

      {:ok, context}
    end
  end

  # Step 9: Use LLM to generate answer with context
  action :generate_answer, Twitter.Tweets.Tweet, :answer_with_context do
    inputs %{
      question: input(:question),
      context: result(:build_context)
    }
  end

  # Step 10: Format the final response
  step :format_response do
    argument :answer, result(:generate_answer)
    argument :tweets, result(:limit_tweets)
    argument :question, input(:question)
    argument :search_queries, result(:generate_queries)
    argument :total_fetched, result(:deduplicate_tweets)
    argument :ranked_tweets, result(:rank_tweets)

    run fn args, _context ->
      response = %{
        question: args.question,
        search_queries: args.search_queries,
        answer: args.answer,
        context_tweets: Enum.map(args.tweets, & &1.text),
        context_count: length(args.tweets),
        total_tweets_fetched: length(args.total_fetched),
        top_relevance_score:
          case args.ranked_tweets do
            [{_tweet, score} | _] -> score
            _ -> nil
          end
      }

      {:ok, response}
    end
  end

  # Return the formatted response
  return :format_response

  # Helper function to calculate cosine distance
  defp cosine_distance(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    dot_product = Enum.zip(vec1, vec2) |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0, fn x, acc -> acc + x * x end))
    1 - dot_product / (magnitude1 * magnitude2)
  end

  defp cosine_distance(_vec1, _vec2), do: 1.0
end
```

**Key improvements over the simple approach:**

- **Parallel Execution**: Three semantic searches run concurrently (Steps 2-4)
- **Multi-Query Coverage**: Generates diverse queries to capture different aspects
- **Deduplication**: Removes duplicate tweets using unique IDs (Step 5)
- **Relevance Ranking**: Sorts by cosine similarity to the original question (Step 6)
- **Smart Limiting**: Takes only the top N most relevant tweets (Step 7)
- **Data Pipeline**: Shows clear transformation steps: fetch → dedupe → rank → limit → contextualize
- **Rich Response**: Returns metadata about the process (queries used, total fetched, relevance scores)

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
policy action([
  :create, :ask, :reformulate_query, 
  :generate_search_queries, :answer_with_context, :ask_with_reactor
]) do
  authorize_if always()
end
```

**Key insight**: You don't need to manually call `Reactor.run/4`. Just pass the
Reactor module to `run` and Ash:

- Automatically maps action arguments to Reactor inputs
- Passes the action context into the Reactor's context
- Handles the Reactor execution lifecycle

### 5. Add Code Interface for the New Action

To make the action easier to call, add it to the code interface in
`lib/twitter/tweets.ex`:

```elixir
resources do
  resource Twitter.Tweets.Tweet do
    define :feed
    define :get_tweet, action: :read, get_by: [:id]
    define :delete_tweet, action: :destroy
    define :ask_tweet_question, action: :ask, args: [:question]
    define :ask_tweet_reactor_question, action: :ask_with_reactor, args: [:question]  # Add this line
  end

  # ... rest of resources
end
```

Now you can call the action directly:
`Twitter.Tweets.ask_tweet_reactor_question("What are people saying about Elixir?")`

### 6. Test the Enhanced Reactor-Based RAG

Test the new Reactor-based action in IEx:

```elixir
# Compare with the simple action from Lab 13
simple_result = Twitter.Tweets.Tweet
|> Ash.ActionInput.for_action(:ask, %{question: "What are people saying about Elixir?"})
|> Ash.run_action!()

IO.puts("Simple action result:")
IO.puts(simple_result)

# Now try the enhanced Reactor-based approach with parallel queries
reactor_result = Twitter.Tweets.Tweet
|> Ash.ActionInput.for_action(:ask_with_reactor, %{
  question: "What are people saying about Elixir?",
  limit: 5
})
|> Ash.run_action!()

IO.puts("\nEnhanced Reactor-based result:")
IO.inspect(reactor_result)

# Output will include multiple search queries and enhanced metadata:
# %{
#   question: "What are people saying about Elixir?",
#   search_queries: ["Elixir programming language", "Elixir features benefits", "Elixir developer experience"],
#   answer: "Based on the tweets...",
#   context_tweets: [...],
#   context_count: 5,
#   total_tweets_fetched: 15,  # Fetched from 3 parallel queries
#   top_relevance_score: 0.92   # Cosine similarity of top tweet
# }
```

Notice how the enhanced Reactor:
- Generated 3 diverse search queries from one user question
- Fetched tweets in parallel for all 3 queries
- Deduplicated results (15 total → 10 unique)
- Ranked by relevance and limited to top 5
- Shows transparency in the process with metadata

## Try on your own

### Challenge Ideas

1. **Dynamic Query Count**: Modify the reactor to accept `num_queries` as an input and dynamically create fetch steps
2. **Weighted Ranking**: Implement ranking that combines cosine similarity with tweet popularity (like count)
3. **Critique and Refine**: Add a step where one LLM critiques another's answer and refines it
4. **Error Handling**: Add retry logic for failed API calls with exponential backoff
5. **Caching**: Cache embeddings and query results to reduce API calls
