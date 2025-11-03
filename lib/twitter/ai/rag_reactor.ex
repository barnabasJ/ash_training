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

  input(:question)
  input(:limit)

  # Step 1: Generate multiple diverse search queries using LLM
  action :generate_queries, Twitter.Tweets.Tweet, :generate_search_queries do
    inputs %{
      question: input(:question),
      num_queries: value(3)
    }
  end

  # Step 2: Fetch tweets for the first query
  read :fetch_tweets_1, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: template("{{ queries[0] }}", queries: result(:generate_queries))
    }

    wait_for [:generate_queries]
  end

  # Step 3: Fetch tweets for the second query (in parallel with fetch_tweets_1)
  read :fetch_tweets_2, Twitter.Tweets.Tweet, :semantic_search do
    inputs %{
      query: template("{{ queries[1] }}", queries: result(:generate_queries))
    }

    wait_for [:generate_queries]
  end

  # Step 4: Fetch tweets for the third query (in parallel with fetch_tweets_1 and fetch_tweets_2)
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
      unique_tweets =
        all_tweets
        |> Enum.uniq_by(& &1.id)

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
                  # Calculate cosine similarity (1 - cosine distance)
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

  # Helper function to calculate cosine distance between two vectors
  defp cosine_distance(vec1, vec2) when is_list(vec1) and is_list(vec2) do
    # Calculate dot product
    dot_product =
      Enum.zip(vec1, vec2)
      |> Enum.reduce(0, fn {a, b}, acc -> acc + a * b end)

    # Calculate magnitudes
    magnitude1 = :math.sqrt(Enum.reduce(vec1, 0, fn x, acc -> acc + x * x end))
    magnitude2 = :math.sqrt(Enum.reduce(vec2, 0, fn x, acc -> acc + x * x end))

    # Cosine distance = 1 - cosine similarity
    1 - dot_product / (magnitude1 * magnitude2)
  end

  defp cosine_distance(_vec1, _vec2), do: 1.0
end
