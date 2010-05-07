require 'rubygems'
require 'right_aws'
require 'logmerge'
require 'ftools'
require 'ralf/interpolation'
require 'chronic'

# Parameters:
#   :config   a YAML config file, if none given it tries to open /etc/ralf.yaml or ~/.ralf.yaml
#   :date     the date to parse _or_
#   :range    a specific range as a string <start> (wicht creates a range to now) or array: [<start>] _or_ [<start>,<stop>]
#             (examples: 'today'; 'yesterday'; 'january'; ['2 days ago', 'yesterday']; )
#   (note:  When :range is supplied it takes precendence over :date)
# 
# These params are also config params (supplied in the params hash, they take precedence over the config file)
#   :aws_access_key_id      (required in config)
#   :aws_secret_access_key  (required in config)
#   :output_basedir               (required in config)
#   :output_prefix             (optional, defaults to 's3_combined')
#   :output_dir_format          (optional, defaults to '') specify directory separators (e.g. ':year/:month/:day')
#   :rename_bucket_keys     (boolean, optional) organize asset on S3 in the same structure as :output_dir_format
#                           (WARNING: there is an extra performance and cost penalty)

# 
# If the required params are given then there is no need to supply a config file
# 

class Ralf
  class ConfigIncomplete < StandardError ; end
  class InvalidRange     < StandardError ; end

  USER_OR_SYSTEM_CONFIG_FILE = [ '~/.ralf.yaml', '/etc/ralf.yaml' ]
  AMAZON_LOG_FORMAT = Regexp.new('([^ ]*) ([^ ]*) \[([^\]]*)\] ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) "([^"]*)" ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) "([^"]*)" "([^"]*)"')
  
  RLIMIT_NOFILE_HEADROOM = 100 # number of file descriptors to allocate above number of logfiles

  # attr :date
  # attr :range
  attr :config
  attr_reader :s3, :buckets_with_logging

  def initialize(args = {})
    @buckets_with_logging = []

    params = args.dup

    read_preferences(params.delete(:config), params)
    self.range = params.delete(:range)

    if @config[:log_file]
      log_file = File.open(File.expand_path(@config[:log_file]), File::WRONLY | File::APPEND | File::CREAT)
    else
      log_file = StringIO.new
    end
    
    RightAws::RightAwsBaseInterface.caching = true # enable caching to speed up
    @s3 = RightAws::S3.new(
            @config[:aws_access_key_id],
            @config[:aws_secret_access_key],
            { :logger => Logger.new(log_file),
              :protocol => 'http', :port => 80 })
  end

  def self.run(params)
    ralf = Ralf.new(params)
    
    if ralf.config[:list_buckets]
      ralf.list_buckets(ralf.config[:buckets])
    else
      ralf.run
    end
  end

  def run
    $stdout.puts "Processing: #{range.begin == range.end ? range.begin : range}"
    
    find_buckets_with_logging(@config[:buckets])
    $stdout.puts @buckets_with_logging.collect {|buc| buc.logging_info.inspect } if ENV['DEBUG']
    @buckets_with_logging.each do |bucket|
      save_logging(bucket)
      merge_to_combined(bucket)
      convert_alt_to_clf(bucket)
    end
  end
  
  def list_buckets(names)
    find_buckets(names).each do |bucket|
      $stdout.print "#{bucket.name}"
      if bucket.logging_info[:enabled]
        $stdout.puts " [#{bucket.logging_info[:targetbucket]}/#{bucket.logging_info[:targetprefix]}]"
      else
        $stdout.puts " [-]"
      end
    end
  end

  # Finds all buckets (in scope of provided credentials) which have logging enabled
  def find_buckets(names)
    # find specified buckets
    if names
      names.map do |name|
        bucket = @s3.bucket(name)
        $stdout.puts "Bucket '#{name}' not found." if bucket.nil?
        bucket
      end
    else
      @s3.buckets
    end
  end

  def find_buckets_with_logging(names = nil)
    buckets = find_buckets(names)

    # remove buckets that don't have logging enabled
    @buckets_with_logging = buckets.map do |bucket|
      bucket.logging_info[:enabled] ? bucket : nil
    end.compact
  end

  def save_logging(bucket)
    range.each do |date|
      save_logging_to_local_disk(bucket, date)
    end
  end

  # Saves files to disk if they do not exists yet
  def save_logging_to_local_disk(bucket, date)

    if bucket.name != bucket.logging_info[:targetbucket]
      puts "logging for '%s' is on '%s'" % [bucket.name, bucket.logging_info[:targetbucket]] if ENV['DEBUG']
      targetbucket = @s3.bucket(bucket.logging_info[:targetbucket])
    else
      targetbucket = bucket
    end

    search_string = "%s%s" % [bucket.logging_info[:targetprefix], date]

    targetbucket.keys(:prefix => search_string).each do |key|

      File.makedirs(local_log_dirname(bucket))
      local_log_file = File.expand_path(File.join(local_log_dirname(bucket), local_log_file_basename(bucket, key)))

      unless File.exists?(local_log_file)
        puts "Writing #{local_log_file}" if ENV['DEBUG']
        File.open(local_log_file, 'w') { |f| f.write(key.data) }
      else
        puts "File exists #{local_log_file}" if ENV['DEBUG']
      end

      if @config[:rename_bucket_keys]
        puts "moving #{key.name} to #{s3_organized_log_file(bucket, key)}" if ENV['DEBUG']
        key.move(s3_organized_log_file(bucket, key))
      end
    end
  end

  # merge all files just downloaded for date to 1 combined file
  def merge_to_combined(bucket)
    in_files = []
    range.each do |date|
      in_files += Dir.glob(File.join(local_log_dirname(bucket), "#{local_log_file_basename_prefix(bucket)}#{date}*"))
    end

    update_rlimit_nofile(in_files.size)
    
    File.open(File.join(@config[:output_basedir], output_alf_file_name(bucket)), 'w') do |out_file|
      LogMerge::Merger.merge out_file, *in_files
    end
  end

  # Convert Amazon log files to Apache CLF
  def convert_alf_to_clf(bucket)
    out_file = File.open(File.join(@config[:output_basedir], output_clf_file_name(bucket)), 'w')
    File.open(File.join(@config[:output_basedir], output_alf_file_name(bucket)), 'r') do |in_file|
      while (line = in_file.gets)
        out_file.puts(translate_to_clf(line))
      end
    end
    out_file.close
  end

  def s3_organized_log_file(bucket, key)
    File.join(log_dir(bucket).gsub(bucket.name + '/',''), output_dir_format, local_log_file_basename(bucket, key))
  end

  def range
    raise ArgumentError unless 2 == @range.size
    Range.new(time_to_date(@range.first), time_to_date(@range.last)) # inclusive
  end
  
  def range=(args)
    args ||= []
    args = [args] unless args.is_a?(Array)

    range = []
    args.each_with_index do |expr, i|
      raise Ralf::InvalidRange, "unused extra argument '#{expr}'" if i > 1
      
      chronic_options = { :context => :past, :guess => false }
      if @config[:now]
        chronic_options.merge!(:now => Chronic.parse(@config[:now], :context => :past))
      end
      
      puts @config[:now].inspect
      
      if span = Chronic.parse(expr, chronic_options)
        if on_same_date?(span)
          range << span.begin
        else
          raise Ralf::InvalidRange, "range end '#{expr}' is not a single date" if i > 0
          range << span.begin
          range << span.end + (@config[:now] ? 0 : -1)
        end
      else
        raise Ralf::InvalidRange, "invalid expression '#{expr}'"
      end
    end
    
    range = [ Date.today ] if range.empty? # empty range means today
    range = range*2 if 1 == range.size     # single day has begin == end
    
    @range = range
  end
  
  def on_same_date?(span)
    span.width <= 24 * 3600
  end
  
  # Create a dynamic output folder
  def output_dir_format
    # TODO: should this be range.begin, or range.end or should the separator
    # be interpolated for each logfile?
    if @config[:output_dir_format]
      Ralf::Interpolation.interpolate(range.end, @config[:output_dir_format])
    else
      ''
    end
  end

  def output_dir_format=(output_dir_format)
    @config[:output_dir_format] = output_dir_format
  end

  def translate_to_clf(line)
    if line =~ AMAZON_LOG_FORMAT
      # host, date, ip, acl, request, status, bytes, agent = $2, $3, $4, $5, $9, $10, $12, $17
      "%s - %s [%s] \"%s\" %d %s \"%s\" \"%s\"" % [$4, $5, $3, $9, $10, $12, $16, $17]
    else
      "# ERROR: #{line}"
    end
  end

  def log_dir(bucket)
    if bucket.logging_info[:targetprefix] =~ /\/$/
      log_dir = "%s/%s" % [bucket.name, bucket.logging_info[:targetprefix].gsub(/\/$/,'')]
    else
      log_dir = File.dirname("%s/%s" % [bucket.name, bucket.logging_info[:targetprefix]])
    end
    log_dir
  end

  # locations of files for this bucket and date
  def local_log_dirname(bucket)
    File.expand_path(File.join(@config[:output_basedir], log_dir(bucket), output_dir_format))
  end

  def local_log_file_basename(bucket, key)
    "%s%s" % [local_log_file_basename_prefix(bucket), key.name.gsub(bucket.logging_info[:targetprefix], '')]
  end

  def local_log_file_basename_prefix(bucket)
    return '' if bucket.logging_info[:targetprefix] =~ /\/$/
    bucket.logging_info[:targetprefix].split('/').last
  end

private

  def output_alf_file_name(bucket)
    "%s%s_%s.alf" % [@config[:output_prefix] || "", bucket.name, range.end]
  end

  def output_clf_file_name(bucket)
    "%s%s_%s.log" % [@config[:output_prefix] || "", bucket.name, range.end]
  end

  def load_user_or_system_config_file
    # attempt YAML load for each default file location in the specified order
    config = nil
    USER_OR_SYSTEM_CONFIG_FILE.each do |config_file|
      begin
        config = YAML.load_file(File.expand_path(config_file))
      rescue Errno::ENOENT
      end
      break if config
    end
    config
  end

  def read_preferences(config_file, params = {})
    @config = {}
    if config_file
      @config = YAML.load_file(File.expand_path(config_file)) || {}
    else
      @config = load_user_or_system_config_file || {}
    end
    
    # define symbolize_keys! method on the instance to convert key strings to symbols
    def @config.symbolize_keys!
      h = self.dup; self.clear; h.each_pair { |k,v| self[k.to_sym] = v }; self
    end

    @config.symbolize_keys!
    @config.merge!(params)
    
    raise ConfigIncomplete.new("--aws-access-key-id required") unless
      (@config[:aws_access_key_id] || ENV['AWS_ACCESS_KEY_ID'])
      
    raise ConfigError.new("--aws-secret-access-key required") unless
      (@config[:aws_secret_access_key] || ENV['AWS_SECRET_ACCESS_KEY'])
    
    @config[:output_basedir] = File.expand_path(@config[:output_basedir] || '.')
  end
  
private
  
  def time_to_date(time)
    Date.new(time.year, time.month, time.day)
  end

  def update_rlimit_nofile(number_of_files)
    new_rlimit_nofile = number_of_files + RLIMIT_NOFILE_HEADROOM

    # getrlimit returns array with soft and hard limit [soft, hard]
    rlimit_nofile = Process::getrlimit(Process::RLIMIT_NOFILE)
    if new_rlimit_nofile > rlimit_nofile.first
      Process.setrlimit(Process::RLIMIT_NOFILE, new_rlimit_nofile) rescue nil
    end 
  end

end
