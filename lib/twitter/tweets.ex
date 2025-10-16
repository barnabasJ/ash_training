defmodule Twitter.Tweets do
  use Ash.Domain,
    extensions: [AshGraphql.Domain, AshJsonApi.Domain, AshAdmin.Domain, AshAi]

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
    tool :read_feed, Twitter.Tweets.Tweet, :feed
    tool :get_tweet, Twitter.Tweets.Tweet, :read
    tool :create_tweet, Twitter.Tweets.Tweet, :create
    tool :like_tweet, Twitter.Tweets.Like, :like
  end
end
