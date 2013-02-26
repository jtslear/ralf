require 'fileutils'

class Ralf::BucketProcessor

  attr_reader :config
  attr_reader :bucket
  attr_reader :open_files

  def initialize(s3_bucket, ralf)
    @bucket = s3_bucket
    @config = ralf.config
    @keys = []
  end

  def process
    file_names_to_process = process_keys_for_range.flatten
    all_loglines = merge(file_names_to_process)
    write_to_combined(all_loglines)
  end

  def process_keys_for_range
    date_range.collect { |date| process_keys_for_date(date)}
  end

  def process_keys_for_date(date)
    puts "\nProcess keys for date #{date}" if config[:debug]
    keys = bucket.keys('prefix' => prefix(date))
    keys.collect { |key| download_key(key) }
  end

  def download_key(key)
    file_name = File.join(cache_dir, key.name.gsub(config[:log_prefix], ''))
    unless File.exist?(file_name)
      print "Downloading: %s\r" % file_name if config[:debug]
      $stdout.flush
      File.open(file_name, 'w') { |f| f.write(key.data) }
    end
    file_name
  end

  def merge(file_names)
    puts "Merging %d files" % file_names.size if config[:debug]
    lines = []
    file_names.collect do |file_name|
      print "Reading: %s \r" % file_name if config[:debug]
      $stdout.flush
      File.open(file_name) do |in_file|
        while (line = in_file.gets)
          translated = Ralf::ClfTranslator.new(line, config)
          lines << {:timestamp => translated.timestamp, :string => translated.to_s}
        end
      end
    end
    puts "\nSorting..." if config[:debug]
    lines.sort! { |a,b| a[:timestamp] <=> b[:timestamp] }
  end

  def write_to_combined(all_loglines)
    puts "Write to Combined" if config[:debug]
    ensure_output_directories
    open_file_descriptors

    all_loglines.each do |line|
      open_files[line[:timestamp].year][line[:timestamp].month][line[:timestamp].day].puts line[:string] if open_files[line[:timestamp].year][line[:timestamp].month][line[:timestamp].day]
    end

  ensure
    close_file_descriptors
  end

  def open_file_descriptors
    @open_files = {}
    date_range_with_ignored_days.each do |date|
      output_filename = Ralf::Interpolation.interpolate(config[:output_dir], {:bucket => bucket.name, :date => date}, [:bucket])
      @open_files[date.year] ||= {}
      @open_files[date.year][date.month] ||= {}
      @open_files[date.year][date.month][date.day] = File.open(output_filename, 'w')
    end
    puts "Opened outputs" if config[:debug]
  end

  def close_file_descriptors
    open_files.each do |year, year_values|
      year_values.each do |month, month_values|
        month_values.each do |day, day_values|
          day_values.close
        end
      end
    end
    puts "Closed outputs" if config[:debug]
  end

  def ensure_output_directories
    date_range_with_ignored_days.each do |date|
      output_filename = Ralf::Interpolation.interpolate(config[:output_dir], {:bucket => bucket.name, :date => date}, [:bucket])
      base_dir = File.dirname(output_filename)
      unless File.exist?(base_dir)
        FileUtils.mkdir_p(base_dir)
      end
    end
  end

  def cache_dir
    @cache_dir ||= begin
      interpolated_cache_dir = Ralf::Interpolation.interpolate(config[:cache_dir], {:bucket => bucket.name}, [:bucket])
      raise Ralf::InvalidConfig.new("Required options: 'Cache dir does not exixst'") unless File.exist?(interpolated_cache_dir)
      interpolated_cache_dir
    end
  end

  def date_range_with_ignored_days
    date_range[config[:days_to_ignore], config[:days_to_look_back]]
  end

  def date_range
    (start_day..Date.today).to_a
  end

private

  def start_day
    Date.today-(config[:days_to_look_back]-1)
  end

  def prefix(date)
    "%s%s" % [config[:log_prefix], date]
  end

end
