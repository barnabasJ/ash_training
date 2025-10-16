defmodule Twitter.Tweets do
  use Ash.Domain,
    extensions: [AshGraphql.Domain, AshJsonApi.Domain, AshAdmin.Domain, AshAi.Domain]

  admin do
    show? true
  end

  resources do
    resource Twitter.Tweets.Tweet do
      define :feed
      define :get_tweet, action: :read, get_by: [:id]
      define :delete_tweet, action: :destroy
    end

    resource Twitter.Tweets.Like do
      define :like, args: [:tweet_id]
      define :unlike, args: [:tweet_id], require_reference?: false
    end
  end

  tools do
    tool :read_feed, Twitter.Tweets.Tweet, :feed do
      description "Retrieve the feed of tweets, sorted by most recent first. Returns a list of tweets with their text, user email, and like count."
      public_fields([:id, :text, :user_email, :like_count, :inserted_at])
      require_actor? true
    end

    tool :get_tweet, Twitter.Tweets.Tweet, :read do
      description "Get a specific tweet by ID"
      argument :id, :uuid, allow_nil?: false
      public_fields([:id, :text, :user_email, :like_count, :inserted_at])
      require_actor? true
    end

    tool :create_tweet, Twitter.Tweets.Tweet, :create do
      description "Create a new tweet with text content"
      argument :text, :string, allow_nil?: false
      require_actor? true
    end

    tool :like_tweet, Twitter.Tweets.Like, :like do
      description "Like a tweet. The current user will be marked as liking the tweet."
      argument :tweet_id, :uuid, allow_nil?: false
      require_actor? true
    end
  end
end
