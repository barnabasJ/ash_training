defmodule Twitter.Tweets.Tweet do
  use Ash.Resource,
    otp_app: :twitter,
    domain: Twitter.Tweets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGraphql.Resource, AshJsonApi.Resource, AshAi, AshOban]

  vectorize do
    # Vectorize the full content of the tweet
    full_text do
      text fn tweet ->
        """
        Tweet: #{tweet.text}
        """
      end

      used_attributes [:text]
    end

    # Store embeddings in this attribute (will be auto-created)
    attributes text: :full_text_vector

    # Use our OpenAI embedding model
    embedding_model Twitter.Ai.OpenAiEmbeddingModel

    # Use ash_oban strategy for async updates
    strategy :ash_oban
  end

  oban do
    triggers do
      trigger :ash_ai_update_embeddings do
        action :ash_ai_update_embeddings
        queue :tweet_vectorizer
        scheduler_cron false
        worker_read_action :read
        worker_module_name Twitter.Tweets.Tweet.AshOban.Worker.AshAiUpdateEmbeddings
        scheduler_module_name Twitter.Tweets.Tweet.AshOban.Scheduler.AshAiUpdateEmbeddings
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    read :feed do
      prepare build(sort: [inserted_at: :desc])
    end

    read :semantic_search do
      argument :query, :string do
        allow_nil? false
        description "The search query to find semantically similar tweets"
      end

      prepare fn query, _context ->
        search_text = Ash.Query.get_argument(query, :query)

        # Generate embedding for the search query
        case Twitter.Ai.OpenAiEmbeddingModel.generate([search_text], []) do
          {:ok, [search_vector]} ->
            query
            |> Ash.Query.sort(
              {calc(vector_cosine_distance(full_text_vector, ^search_vector), type: :float), :asc}
            )
            |> Ash.Query.limit(10)

          {:error, error} ->
            Ash.Query.add_error(query, error)
        end
      end
    end

    action :ask, :string do
      argument :question, :string do
        allow_nil? false
        description "The question to ask about tweets"
      end

      argument :limit, :integer do
        default 3
        description "Number of context tweets to retrieve"
      end

      argument :context, :string do
        public? false
        allow_nil? true
      end

      prepare fn input, _context ->
        question = input.arguments.question
        limit = input.arguments.limit

        context_tweets =
          Twitter.Tweets.Tweet
          |> Ash.Query.for_read(:semantic_search, %{query: question})
          |> Ash.Query.limit(limit)
          |> Ash.read!()
          |> Enum.map(fn tweet ->
            "- \"#{tweet.text}\""
          end)

        Ash.ActionInput.set_argument(input, :context, Enum.join(context_tweets, "\n"))
      end

      run prompt(
            LangChain.ChatModels.ChatOpenAI.new!(%{model: "gpt-4o-mini"}),
            prompt: """
            You are a helpful assistant answering questions about tweets.

            Here are some relevant tweets from our database:

            <%= @input.arguments.context %>

            User's question: <%= @input.arguments.question %>

            Please provide a helpful, concise answer based on the tweets above.
            If the tweets don't contain relevant information, acknowledge that
            and provide a general response.
            """,
            verbose?: true
          )
    end

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

    # Reactor-based RAG action
    action :ask_with_reactor, :map do
      argument :question, :string, allow_nil?: false
      argument :limit, :integer, default: 5

      # Pass the Reactor module directly - Ash handles execution automatically
      run Twitter.Ai.RagReactor
    end

    create :create do
      accept [:text]

      change relate_actor(:user)

      validate string_length(:text, max: 255)
    end

    update :update do
      accept [:text]

      validate string_length(:text, max: 255)
    end
  end

  policies do
    # Allow AshAi to update embeddings
    bypass action(:ash_ai_update_embeddings) do
      authorize_if AshOban.Checks.AshObanInteraction
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :ask, :reformulate_query, :answer_with_context, :ask_with_reactor]) do
      authorize_if always()
    end

    policy action([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      public? true
    end

    timestamps()
  end

  calculations do
    calculate :text_length, :integer, expr(string_length(text)), public?: true
    calculate :liked_by_me, :boolean, expr(exists(likes, user_id == ^actor(:id))), public?: true
  end

  aggregates do
    count :like_count, :likes do
      public? true
    end

    first :user_email, :user, :email do
      authorize? false
      public? true
    end
  end

  postgres do
    table "tweets"
    repo Twitter.Repo
  end

  relationships do
    belongs_to :user, Twitter.Accounts.User do
      allow_nil? false
    end

    has_many :likes, Twitter.Tweets.Like
  end

  json_api do
    type "tweet"

    routes do
      base "/tweets"

      index :feed
    end
  end

  graphql do
    type :tweet

    queries do
      list :feed, :feed
    end
  end
end
