defmodule Twitter.Ai.RagReactorTest do
  use Twitter.DataCase, async: false

  alias Twitter.Tweets.Tweet

  describe "ask_with_reactor/2" do
    setup do
      # Create some test tweets with embeddings
      {:ok, tweet1} =
        Tweet
        |> Ash.Changeset.for_create(:create, %{text: "Elixir is great for performance"})
        |> Ash.create()

      {:ok, tweet2} =
        Tweet
        |> Ash.Changeset.for_create(:create, %{text: "Phoenix is fast and reliable"})
        |> Ash.create()

      {:ok, tweet3} =
        Tweet
        |> Ash.Changeset.for_create(:create, %{text: "I love coding in Elixir"})
        |> Ash.create()

      # Wait for embeddings to be generated (in real app, this would be async)
      # For testing, we might need to manually trigger embedding generation
      # or mock the embedding service

      %{tweets: [tweet1, tweet2, tweet3]}
    end

    @tag :skip
    test "returns structured response with reformulated query", %{tweets: _tweets} do
      # This test requires OpenAI API key to be set
      # Skip by default unless running integration tests

      result =
        Tweet
        |> Ash.ActionInput.for_action(:ask_with_reactor, %{
          question: "What are people saying about Elixir?",
          limit: 5
        })
        |> Ash.run_action!()

      assert is_map(result)
      assert Map.has_key?(result, :question)
      assert Map.has_key?(result, :search_query)
      assert Map.has_key?(result, :answer)
      assert Map.has_key?(result, :context_tweets)
      assert Map.has_key?(result, :context_count)

      assert result.question == "What are people saying about Elixir?"
      assert is_binary(result.search_query)
      assert is_binary(result.answer)
      assert is_list(result.context_tweets)
      assert is_integer(result.context_count)
    end
  end

  describe "reformulate_query/1" do
    @tag :skip
    test "reformulates question into search query" do
      # This test requires OpenAI API key to be set
      result =
        Tweet
        |> Ash.ActionInput.for_action(:reformulate_query, %{
          question: "What are people saying about Elixir's performance?"
        })
        |> Ash.run_action!()

      assert is_binary(result)
      # The result should be a concise search query
      assert String.length(result) < 100
    end
  end

  describe "answer_with_context/2" do
    @tag :skip
    test "generates answer using provided context" do
      # This test requires OpenAI API key to be set
      context = """
      - "Elixir is great for performance"
      - "Phoenix is fast and reliable"
      """

      result =
        Tweet
        |> Ash.ActionInput.for_action(:answer_with_context, %{
          question: "Is Elixir fast?",
          context: context
        })
        |> Ash.run_action!()

      assert is_binary(result)
      # The answer should reference the context
      assert String.length(result) > 10
    end
  end
end
