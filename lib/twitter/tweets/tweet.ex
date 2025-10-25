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

    policy action(:create) do
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
