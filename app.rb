require 'sinatra/base'
require 'mongo_mapper'
require 'koala'
require 'yaml'
require 'redis'

class User
  include MongoMapper::Document

  key :user_id, String, :required => true
  key :email,   String, :required => true
  key :token,   String, :required => true

  timestamps!
end


class Digger < Sinatra::Base

  include Koala

  configure do
    enable :sessions

    config = YAML.load_file(File.expand_path('config.yml',File.dirname(__FILE__)))
    set :app_id, config['app_id']
    set :secret, config['secret']
    set :url,    config['url'] || 'http://localhost:4567/'

    MongoMapper.database = 'postsearch'

    $redis = Redis.new
  end

  helpers do
    def logged_in?
      !!session['access_token']
    end
  end

  get '/' do
    if logged_in?
      redirect '/home'
    end

    erb :index
  end

  get '/home' do
    if !logged_in?
      redirect '/'
    end

    @graph = Facebook::API.new(session['access_token'])
    @me    = @graph.get_object('me');
    @pals  = @graph.get_connections('me','friends')

    @pals.each do |pal|
      $redis.hset(session['me'], pal['name'].gsub(' ','_'), pal['id'])
      $redis.expire(session['me'],3600)
    end

    erb :home
  end

  get '/search' do
    content_type :json

    query = params[:query]
    user  = params[:user]
    graph = @graph ||= Facebook::API.new(session['access_token'])

    friend_id = $redis.hget(session['me'], "#{user.gsub(' ','_')}")

    fql_q = "select actor_id,post_id,message,created_time from stream where source_id = #{friend_id} limit 1000"
    posts = graph.fql_query(fql_q)

    @matches = posts.select { |p| p['message'] =~ /#{query}/ }

    p @matches.to_json
  end

  get '/login' do
    session['oauth'] = Facebook::OAuth.new(settings.app_id, settings.secret, settings.url+'callback')

    redirect session['oauth'].url_for_oauth_code(:permissions => 'read_stream,user_status,friends_status,email')
  end

  get '/logout' do
    graph = @graph ||= Facebook::API.new(session['access_token'])
    me = graph.get_connection('me')

    $redis.del(session['me'])

    session['oauth'] = nil
    session['access_token'] = nil
    session['me'] = nil

    redirect '/'
  end

  get '/callback' do
    session['access_token'] = session['oauth'].get_access_token(params[:code])

    graph = @graph ||= Facebook::API.new(session['access_token'])
    user = graph.get_object('me')

    email = user['email']
    id = user['id']
    token = session['access_token']

    user = User.first(user_id: id)
    if(user)
      user.update_attributes!(user_id: id, token: token, email: email)
      session['me'] = id
    else
      User.create!(user_id: id, token: token, email: email)
    end

    redirect '/home'
  end

  run! if app_file == $0
end
