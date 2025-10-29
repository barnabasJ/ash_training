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
      define :ask_tweet_question, action: :ask, args: [:question]
      define :ask_tweet_reactor_question, action: :ask_with_reactor, args: [:question]
    end

    resource Twitter.Tweets.Like do
      define :like, args: [:tweet_id]
      define :unlike, args: [:tweet_id], require_reference?: false
    end
  end

  tools do
    tool :read_feed, Twitter.Tweets.Tweet, :feed do
      description "Retrieve the feed of tweets, sorted by most recent first"
    end

    tool :read_tweet, Twitter.Tweets.Tweet, :read do
      description "Retrieve a list of tweets, also supports filtering, sorting, and more"
    end

    tool :semantic_search_tweets, Twitter.Tweets.Tweet, :semantic_search do
      description "Perform a semantic search over tweets based on a query string"
    end

    tool :create_tweet, Twitter.Tweets.Tweet, :create do
      description "Create a new tweet with text content"
    end

    tool :like_tweet, Twitter.Tweets.Like, :like do
      description "Like a tweet. The current user will be marked as liking the tweet."
    end

    tool :unlike_tweet, Twitter.Tweets.Like, :unlike do
      description "Unlike a tweet. The current user will be unmarked as liking the tweet."
      identity false
    end
  end
end
