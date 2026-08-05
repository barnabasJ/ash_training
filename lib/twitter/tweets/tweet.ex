defmodule Twitter.Tweets.Tweet do
  use Ash.Resource,
    otp_app: :twitter,
    domain: Twitter.Tweets,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshGraphql.Resource, AshJsonApi.Resource, AshAi, AshOban]

  vectorize do
    full_text do
      text fn tweet ->
        """
        Tweet: #{tweet.text}
        """
      end

      used_attributes [:text]
    end

    attributes text: :full_text_vector

    embedding_model {AshAi.EmbeddingModels.ReqLLM,
                     model: "openai:text-embedding-3-small", dimensions: 1536}

    strategy :ash_oban
  end

  oban do
    triggers do
      trigger :ash_ai_update_embeddings do
        action :ash_ai_update_embeddings
        queue :tweet_vectorizer
        worker_read_action :read
        worker_module_name Twitter.Tweets.Tweet.AshOban.Worker.AshAiUpdateEmbeddings
        scheduler_module_name Twitter.Tweets.Tweet.AshOban.Scheduler.AshAiUpdateEmbeddings
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :text, :string do
      public? true
    end

    timestamps()
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:text]

      change relate_actor(:user)

      validate string_length(:text, max: 255)
    end

    update :update do
      accept [:text]

      validate string_length(:text, max: 255)
    end

    read :feed do
      prepare build(sort: [inserted_at: :desc])
    end

    read :semantic_search do
      argument :query, :string, allow_nil?: false

      prepare fn query, _context ->
        search_text = Ash.Query.get_argument(query, :query)

        case AshAi.EmbeddingModels.ReqLLM.generate([search_text],
               model: "openai:text-embedding-3-small",
               dimensions: 1536
             ) do
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

      run prompt("openai:gpt-4o-mini",
            prompt: """
            You are a helpful assistant answering questions about tweets.

            Here are some relevant tweets from our database:

            <%= @input.arguments.context %>

            User's question: <%= @input.arguments.question %>

            Please provide a helpful, concise answer based on the tweets above.
            If the tweets don't contain relevant information, acknowledge that
            and provide a general response.
            """
          )
    end
  end

  policies do
    bypass action(:ash_ai_update_embeddings) do
      authorize_if AshOban.Checks.AshObanInteraction
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :ask]) do
      authorize_if always()
    end

    policy action([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  calculations do
    calculate :text_length, :integer, expr(string_length(text))
    calculate :liked_by_me, :boolean, expr(exists(likes, user_id == ^actor(:id)))
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

    custom_indexes do
      index ["full_text_vector vector_cosine_ops"],
        name: "tweets_full_text_vector_index",
        using: "hnsw",
        concurrently: false
    end
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
      get :read, primary?: true
    end
  end

  graphql do
    type :tweet

    queries do
      list :feed, :feed
    end
  end
end
