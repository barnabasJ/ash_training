defmodule Twitter.Tweets do
  use Ash.Domain,
    extensions: [AshJsonApi.Domain, AshAdmin.Domain]

  admin do
    show? true
  end

  json_api do
    prefix "/api/json"
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
end
