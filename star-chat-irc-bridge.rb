# encoding: utf-8

require 'json'
require 'net/http'
require 'net/irc'
require 'thread'
require 'uri'
require 'yaml'

# Implementing on_idle
# http://coderepos.org/share/browser/lang/ruby/bgpwatch/trunk/lib/monkey-patch/net-irc-client.rb
class Net::IRC::Client
  def start
    # reset config
    @server_config = Message::ServerConfig.new
    @socket = TCPSocket.open(@host, @port)
    on_connected
    post PASS, @opts.pass if @opts.pass
    post NICK, @opts.nick
    post USER, @opts.user, "0", "*", @opts.real
    # ---- cut here ----
    while true
      r = select([@socket], [], [@socket], 1)
      if r.nil? then
        send(:on_idle) if respond_to?(:on_idle)
        next
      elsif @socket.eof? then
        break
      end
      l = @socket.gets
      # ---- cut here ----
      
      begin
        @log.debug "RECEIVE: #{l.chomp}"
        m = Message.parse(l)
        next if on_message(m) === true
        name = "on_#{(COMMANDS[m.command.upcase] || m.command).downcase}"
        send(name, m) if respond_to?(name)
      rescue Exception => e
        warn e
        warn e.backtrace.join("\r\t")
        raise
      rescue Message::InvalidMessage
        @log.error "MessageParse: " + l.inspect
      end
    end
  rescue IOError
  ensure
    finish
  end
end

$config = open(ARGV[0] ? ARGV[0] : 'config.yaml') do |io|
  YAML.load(io)
end

if $config['daemonized']
  Process.daemon(true)
end

class StarChatClient

  def check_response(res)
    return true if res.code == '409'
    return false if res.code.to_i / 100 != 2
    true
  end

  def check_response!(res)
    return if res.code == '409'
    raise res.message if res.code.to_i / 100 != 2
  end
  private :check_response!

  def initialize(irc_client, host, port, name, nick, pass)
    @host = host
    @port = port
    @name = name
    @nick = nick
    @pass = pass
    res = Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Put.new('/users/' + URI.encode_www_form_component(@name))
      req.basic_auth(@name, @pass)
      req.set_form_data(nick: @nick)
      http.request(req)
    end
    check_response!(res)
    @stream_thread = Thread.new do
      begin
        loop do
          puts "Connecting StarChat..."
          begin
            url = '/users/' + URI.encode_www_form_component(@name) + '/stream'
            Net::HTTP.start(@host, @port) do |http|
              req = Net::HTTP::Get.new(url)
              req.basic_auth(@name, @pass)
              req.set_form_data(nick: @nick)
              http.request(req) do |res|
                res.read_body do |body|
                  body.split(/\n/).select do |line|
                    !line.empty?
                  end.map do |line|
                    begin
                      JSON.parse(line)
                    rescue JSON::ParserError
                      puts("JSON::ParserError!: #{line}")
                      nil
                    end
                  end.each do |packet|
                    next unless packet
                    next if packet['type'] != 'message'
                    message = packet['message']
                    next unless message
                    next if message['user_name'] == @name
                    pair = $config['channels'].select{|pair|
                      pair['star_chat'] == message['channel_name']
                    }.first
                    next unless pair
                    irc_ch = pair['irc'].force_encoding('utf-8')
                    name = message['user_name'].force_encoding('utf-8')
                    name_with_spaces = name.split(//).join("\ufeff")
                    body   = "(#{name_with_spaces}) #{message['body'].force_encoding('utf-8')}"
                    notice = (message['notice'] || false)
                    puts "Request: #{irc_ch}, #{body}"
                    irc_client.request_post_message(irc_ch, body, notice)
                  end
                end
              end
            end
          rescue Timeout::Error
          rescue IOError
          end
          sleep(1)
        end
      rescue Exception => e
        File.open('log.txt', 'a') do |io|
          io.puts(e.message)
          io.puts(e.backtrace.join("\n"))
        end
        raise
      ensure
        puts "Thread is ending now."
      end
    end
  end

  def put_subscribing(channel_name)
    return unless channel_name.valid_encoding?
    res = Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Put.new('/subscribings')
      req.basic_auth(@name, @pass)
      req.set_form_data(channel_name: channel_name,
                        user_name:    @name)
      http.request(req)
    end
    unless check_response(res)
      puts res.message
    end
  end

  def post_message(channel_name, irc_nick, body, notice = false)
    return unless channel_name.valid_encoding?
    return unless body.valid_encoding?
    url = '/channels/' + URI.encode_www_form_component(channel_name) + '/messages'
    res = Net::HTTP.start(@host, @port) do |http|
      req = Net::HTTP::Post.new(url)
      req.basic_auth(@name, @pass)
      # The argumennt notice is ignored now.
      req.set_form_data(body:           body,
                        notice:         notice ? 'true' : 'false',
                        temporary_nick: irc_nick)
      http.request(req)
    end
    unless check_response(res)
      puts res.message
    end
  end

end

class StarChatIRCBridge < Net::IRC::Client

  def on_rpl_welcome(m)
    @requests = Queue.new

    star_chat_server_config = $config['star_chat_server']
    star_chat_user_config   = $config['star_chat_user']
    @star_chat_client = StarChatClient.new(self,
                                           star_chat_server_config['host'],
                                           star_chat_server_config['port'],
                                           star_chat_user_config['name'],
                                           star_chat_user_config['nick'],
                                           star_chat_user_config['pass'])
    $config['channels'].each do |pair|
      irc_ch, star_chat_ch = pair['irc'], pair['star_chat']
      post(JOIN, irc_ch)
      @star_chat_client.put_subscribing(star_chat_ch)
    end
  end

  def to_star_chat_msg(m)
    irc_ch, irc_message = *m
    irc_nick = /^(.+?)\!/.match(m.prefix)[1]
    pair = $config['channels'].select{|pair|
      pair['irc'].downcase == irc_ch.downcase
    }.first
    return [nil, nil, nil] unless pair
    star_chat_ch = pair['star_chat']
    return unless star_chat_ch
    body = irc_message
    [irc_nick, star_chat_ch, body].map do |str|
      str.force_encoding('utf-8')
    end
  end
  private :to_star_chat_msg

  def on_privmsg(m)
    super
    irc_nick, star_chat_ch, body = to_star_chat_msg(m)
    return unless irc_nick
    return unless star_chat_ch
    return unless body
    return if irc_nick == $config['irc_user']['nick']
    @star_chat_client.post_message(star_chat_ch, irc_nick, body)
  end

  def on_notice(m)
    super
    irc_nick, star_chat_ch, body = to_star_chat_msg(m)
    return unless irc_nick
    return unless star_chat_ch
    return unless body
    return if irc_nick == $config['irc_user']['nick']
    @star_chat_client.post_message(star_chat_ch, irc_nick, body, true)
  end

  def on_idle
    return unless @requests
    until @requests.empty?
      request = @requests.pop
      case request[:type]
      when :post_message
        irc_ch = request[:irc_ch]
        body   = request[:body]
        notice = request[:notice] # ignore!
        post(notice ? NOTICE : PRIVMSG, irc_ch, body)
      end
    end
  end

  def request_post_message(irc_ch, body, notice = false)
    @requests << {
      type:   :post_message,
      irc_ch: irc_ch,
      body:   body,
      notice: notice,
    }
  end

end

irc_server_config = $config['irc_server']
irc_user_config   = $config['irc_user']
$b = StarChatIRCBridge.new(irc_server_config['host'],
                           irc_server_config['port'].to_i,
                           nick: irc_user_config['nick'],
                           user: irc_user_config['user'],
                           real: irc_user_config['real'])
$b.start
