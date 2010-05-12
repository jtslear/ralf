require File.dirname(__FILE__) + '/spec_helper'

require 'ralf'

CONFIG_FIXTURE_PATH = File.expand_path(File.dirname(__FILE__) + '/fixtures/config.yaml')
# FULL_CONFIG_PATH    = File.expand_path(CONFIG_PATH)
CONFIG_FIXTURE_YAML = YAML.load_file(CONFIG_FIXTURE_PATH)

describe Ralf do

  before(:all) do
    # make sure we don't accidentally use actual credentials during test
    ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'] = nil, nil
    
    @key1 = {
      :name => 'log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT',
      :data => 'This is content for key 1'
    }
    @key2 = {
      :name => 'log/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH',
      :data => 'This is content for key 2'
    }
    @key3 = {
      :name => 'log/access_log-2010-02-11-00-09-32-SDHTFTFHDDDDDH',
      :data => 'This is content for key 3'
    }
    
    @aws_credentials = {
      :aws_access_key_id     => 'the_aws_access_key_id',
      :aws_secret_access_key => 'the_secret_access_key',
    }
    
    @valid_options = {
      :config_file => '',
      :output_file => './ralf/:year/:month/:day/:bucket.log',
    }.merge(@aws_credentials)
    
    @cli_config_path = 'my_ralf.conf'
    @cli_config = {
      :range       => '2010-02-10',
      :output_file => './ralf/:year/:month/:day/:bucket.log',
      :cache_dir   => '/tmp/ralf_cache/:bucket',
    }.merge(@aws_credentials)

    @tilde_config_path = File.expand_path('~/.ralf.conf')
    @tilde_config = {
      :range       => '2010-02-11',
      :output_file => '~/ralf/:year/:month/:day/:bucket.log',
      :cache_dir   => '~/ralf/cache/:bucket',
    }.merge(@aws_credentials)

    @etc_config_path = '/etc/ralf.conf'
    @etc_config = {
      :range       => '2010-02-12',
      :output_file => '/var/log/amazon/:year/:month/:day/:bucket.log',
      :cache_dir   => '/var/log/amazon/ralf_cache/:year/:month/:bucket',
    }.merge(@aws_credentials)
    
    # File = mock('File')
  end

  before(:each) do
    # TODO find out why next line only behaves as expected in before(:each)
    # it should really work OK in before(:all)
    RightAws::S3.should_receive(:new).any_number_of_times.and_return(mock('RightAws::S3'))
  end

  describe "Options" do

    it "should initialize properly" do
      ralf = Ralf.new({:output_file => 'here'}.merge(@aws_credentials))
      ralf.class.should eql(Ralf)
    end
    
    it "should read config file specified on command-line" do
      YAML.should_receive(:load_file).with(@cli_config_path).and_return(@cli_config)
      YAML.should_not_receive(:load_file).with(@tilde_config_path)
      YAML.should_not_receive(:load_file).with(@etc_config_path)
      ralf = Ralf.new(:config_file => @cli_config_path)
      ralf.config.should == Ralf::Config.new(@cli_config)
    end
    
    it "should read config file from '~/.ralf.conf' if it exists." do
      File.should_receive(:exist?).with(@tilde_config_path).and_return(true)
      YAML.should_receive(:load_file).with(@tilde_config_path).and_return(@tilde_config)
      ralf = Ralf.new
      ralf.config.should == Ralf::Config.new(@tilde_config)
    end
    
    it "should read config file from '/etc/ralf.conf' if ~/.ralf.conf does not exist." do
      File.should_receive(:exist?).with(@tilde_config_path).and_return(false)
      File.should_receive(:exist?).with(@etc_config_path).and_return(true)
      YAML.should_receive(:load_file).with(@etc_config_path).and_return(@etc_config)
      ralf = Ralf.new
      ralf.config.should == Ralf::Config.new(@etc_config)
    end
    
    it "should have only required option when :config_file is empty string" do
      File.should_not_receive(:exist?)
      ralf = Ralf.new({ :config_file => '', :list => true }.merge(@aws_credentials))
      ralf.config.should == Ralf::Config.new({ :list => true }.merge(@aws_credentials))
    end
    
    it "command-line options should override config file options" do
      File.should_receive(:exist?).with(@tilde_config_path).and_return(true)
      YAML.should_receive(:load_file).with(@tilde_config_path).and_return(@tilde_config)
      ralf = Ralf.new(@cli_config)
      ralf.config.should == Ralf::Config.new(@cli_config)
    end
  
    it "should raise an error when an nonexistent config file is given" do
      missing_file = 'the_missing_file.conf'
      File.should_receive(:open).with(missing_file).and_raise(Errno::ENOENT)
      lambda {
        ralf = Ralf.new(:config_file => missing_file)
      }.should raise_error(Errno::ENOENT)
    end

    it "should set the preferences" do
      ralf = Ralf.new(@cli_config)
      ralf.config.should == Ralf::Config.new(@cli_config)
    end
    
    it "should raise Ralf::Config::ConfigurationError when --output-file not specified" do
      lambda {
        Ralf.new(:output_file => nil)
      }.should raise_error(Ralf::Config::ConfigurationError)
    end

    it "should use AWS credentials provided in ENV" do
      lambda {
        Ralf.new(:list => true)
      }.should raise_error(Ralf::Config::ConfigurationError, 'aws_access_key_id missing, aws_secret_access_key missing')

      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'] = 'aws_access_key', 'secret'
      lambda {
        Ralf.new(:list => true)
      }.should_not raise_error(Ralf::Config::ConfigurationError)
      
      # reset
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'] = nil, nil
    end

  end

  describe "Range handling" do
    
    it "should set range to today if unspecified" do
      now = Time.now
      Time.should_receive(:now).and_return(now)
      ralf = Ralf.new(@valid_options)
      date = now.strftime("%Y-%m-%d")

      ralf.config.range.to_s.should eql("#{date}..#{date}")
    end

    it "should set the range when single date given" do
      ralf = Ralf.new(@valid_options.merge(:range => '2010-02-01'))
      ralf.config.range.to_s.should eql('2010-02-01..2010-02-01')
    end

    it "should raise error when invalid date given" do
      lambda {
        ralf = Ralf.new(@valid_options.merge(:range => 'someday'))
        ralf.range.should be_nil
      }.should raise_error(Ralf::Config::RangeError, "invalid expression 'someday'")
    end

    it "should accept a range of 2 dates" do
      ralf = Ralf.new(@valid_options.merge(:range => ['2010-02-10', '2010-02-12']))
      ralf.config.range.to_s.should eql('2010-02-10..2010-02-12')
    end
    
    it "should raise error for range array with more than 2 items" do
      lambda {
        ralf = Ralf.new(@valid_options.merge(:range => ['2010-02-10', '2010-02-12', '2010-02-13']))
      }.should raise_error(ArgumentError, 'too many range items')
    end

    it "should treat a range with 1 date as a single date" do
      ralf = Ralf.new(@valid_options.merge(:range => '2010-02-10'))
      ralf.config.range.to_s.should eql('2010-02-10..2010-02-10')
    end

    it "should accept a range array with 1 date" do
      ralf = Ralf.new(@valid_options.merge(:range => ['2010-02-10']))
      ralf.config.range.to_s.should eql('2010-02-10..2010-02-10')
    end

    it "should accept a range defined by words" do
      Time.should_receive(:now).exactly(4).times.and_return(Time.parse('Mon Feb 17 09:41:00 +0100 2010'))
      ralf = Ralf.new(@valid_options.merge(:range => '2 days ago'))
      ralf.config.range.to_s.should eql('2010-02-15..2010-02-15')
    end

    it "should accept a month and convert it to a range" do
      Time.should_receive(:now).exactly(3).times.and_return(Time.parse('Mon Feb 17 09:41:00 +0100 2010'))
      ralf = Ralf.new(@valid_options.merge(:range => 'january'))
      ralf.config.range.to_s.should  eql('2010-01-01..2010-01-31')
    end
    
    xit "should allow 'this month' with base 'yesterday'" do
      Time.should_receive(:now).exactly(3).times.and_return(Time.parse('Sat May 01 16:31:00 +0100 2010'))
      ralf = Ralf.new(@valid_options.merge(:range => 'this month', :now => 'yesterday'))
      ralf.config.range.to_s.should  eql('2010-04-01..2010-04-30')
    end

  end

  describe "Handle Buckets" do

    before(:each) do
      @ralf = Ralf.new(@valid_options)
      @bucket1 = mock('bucket1')
      @bucket2 = mock('bucket2')
    end

    it "should find buckets with logging enabled" do
      @ralf.s3.should_receive(:buckets).once.and_return([@bucket1, @bucket2])
      @bucket1.should_receive(:logging_info).and_return({ :enabled => true,  :targetprefix => "log/access_log-", :targetbucket => 'bucket1' })
      @bucket2.should_receive(:logging_info).and_return({ :enabled => false, :targetprefix => "log/",            :targetbucket => 'bucket2' })

      @ralf.find_buckets_with_logging.should eql([@bucket1])
      @ralf.buckets_with_logging.should      eql([@bucket1])
    end

    xit "should return the new organized path" do
      File.should_receive(:dirname).with("bucket1/log/access_log-").and_return('bucket1/log')
      File.should_receive(:join) { |*args| args.join('/') }
      
      @ralf.s3_organized_log_file('bucket1', 'log/access_log-', 'log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT').should eql('log/2010/02/10/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT')
    end

    describe "logging" do

      before(:each) do
        @key1.should_receive(:name).any_number_of_times.and_return(@key1[:name])
        @key2.should_receive(:name).any_number_of_times.and_return(@key2[:name])
        @key1.should_receive(:data).any_number_of_times.and_return(@key1[:data])
        @key2.should_receive(:data).any_number_of_times.and_return(@key2[:data])
      end

      xit "should save logging to disk" do
        @bucket1.should_receive(:keys).any_number_of_times.and_return([@key1, @key2])

        dir = '/Test/Users/test_user/S3/bucket1/log/2010/02/10'
        file1 = "#{dir}/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT"
        file2 = "#{dir}/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH"
        File.should_receive(:makedirs).with(dir).and_return(true)
        File.should_receive(:exists?).once.with(file1).and_return(true)
        File.should_receive(:exists?).once.with(file2).and_return(false)
        File.should_receive(:open).once.with(   file2, "w").and_return(true)

        File.should_receive(:dirname).any_number_of_times.with("bucket1/log/access_log-").and_return('bucket1/log')

        [ dir, file1, file2 ].each do |path|
          File.should_receive(:expand_path).any_number_of_times.with(path).and_return(path)
        end

        @bucket1.should_receive(:name).exactly(4).times.and_return('bucket1')
        @bucket1.should_receive(:logging_info).and_return({ :enabled => true, :targetprefix => "log/access_log-", :targetbucket => 'bucket1' })

        @ralf.save_logging_to_local_disk(@bucket1, @bucket1.logging_info, '2010-02-10').should eql([@key1, @key2])
      end

      xit "should save logging for range to disk" do
        pending "TODO: fix this spec or the implementation" do
          @bucket1.should_receive(:keys).any_number_of_times.and_return([@key1, @key2], [@key3], [])
          @key3.should_receive(:name).any_number_of_times.and_return(@key3[:name])
          @key3.should_receive(:data).any_number_of_times.and_return(@key3[:data])

          @ralf.range = ['2010-02-10', '2010-02-12']

          dir1 = '/Test/Users/test_user/S3/bucket1/log/2010/02/10'
          dir2 = '/Test/Users/test_user/S3/bucket1/log/2010/02/11'
          File.should_receive(:exists?).once.with("#{dir1}/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT").and_return(false)
          File.should_receive(:exists?).once.with("#{dir1}/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH").and_return(true)
          File.should_receive(:exists?).once.with("#{dir2}/access_log-2010-02-11-00-09-32-SDHTFTFHDDDDDH").and_return(false)
          File.should_receive(:open).once.with(   "#{dir1}/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT", "w").and_return(StringIO.new)
          File.should_receive(:open).once.with(   "#{dir2}/access_log-2010-02-11-00-09-32-SDHTFTFHDDDDDH", "w").and_return(StringIO.new)
        
          File.should_receive(:makedirs).twice.with(dir1)
          File.should_receive(:makedirs).once.with(dir2)

          @ralf.save_logging(@bucket1).class.should  eql(Range)
        end
      end

      xit "should save logging if a different targetbucket is given" do
        @ralf.s3.should_receive(:bucket).and_return(@bucket1)
        @bucket3 = {:name => 'bucket3'}
        @bucket3.should_receive(:logging_info).any_number_of_times.and_return({ :enabled => false, :targetprefix => "log/", :targetbucket => 'bucket1' })
        @bucket3.should_receive(:name).any_number_of_times.and_return(@bucket3[:name])
        @bucket1.should_receive(:keys).any_number_of_times.and_return([@key1, @key2])

        dir = '/Test/Users/test_user/S3/bucket3/log/2010/02/10'
        File.should_receive(:expand_path).with(dir).and_return(dir)
        File.should_receive(:join).any_number_of_times { |*args| args.join('/') }

        File.should_receive(:makedirs).with(dir)

        @ralf.save_logging_to_local_disk(@bucket3, @bucket3.logging_info, '2010-02-10').should eql([@key1, @key2])
      end

    end

    xit "should merge all logs" do
      out_string = StringIO.new

      Dir.should_receive(:glob).with('/Test/Users/test_user/S3/bucket1/log/2010/02/10/access_log-2010-02-10*').and_return(
          ['/Test/Users/test_user/S3/bucket1/log/2010/02/10/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT',
           '/Test/Users/test_user/S3/bucket1/log/2010/02/10/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH'])

      File.should_receive(:open).with('/Test/Users/test_user/S3/s3_combined_bucket1_2010-02-10.alf', "w").and_yield(out_string)

      LogMerge::Merger.should_receive(:merge).with(
        out_string, 
        '/Test/Users/test_user/S3/bucket1/log/2010/02/10/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT',
        '/Test/Users/test_user/S3/bucket1/log/2010/02/10/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH'
      )

      File.should_receive(:dirname).with("bucket1/log/access_log-").and_return('bucket1/log')
      File.should_receive(:join).any_number_of_times { |*args| args.join('/') }
      
      File.should_receive(:expand_path).with('/Test/Users/test_user/S3/bucket1/log/2010/02/10').and_return('/Test/Users/test_user/S3/bucket1/log/2010/02/10')
      
      # simulate small RLIMIT_NOFILE limit, then Ralf will set appropariate new RLIMIT_NOFILE
      Process.should_receive(:getrlimit).with(Process::RLIMIT_NOFILE).and_return([10, 10])
      Process.should_receive(:setrlimit).with(Process::RLIMIT_NOFILE, 2 + 100)

      @bucket1.should_receive(:logging_info).and_return({ :enabled => true, :targetprefix => "log/access_log-", :targetbucket => 'bucket1' })
      @bucket1.should_receive(:name).twice.and_return('bucket1')
      
      @ralf.merge_to_combined(@bucket1)

      out_string.string.should eql('')
    end

    xit "should save logs which have a targetprefix containing a '/'" do
      File.should_receive(:dirname).with("bucket1/log/access_log-").and_return('bucket1/log')
      
      bucket1_path = '/Test/Users/test_user/S3/bucket1/log/2010/02/10'
      bucket2_path = '/Test/Users/test_user/S3/bucket2/log/2010/02/10'
      [ bucket1_path, bucket2_path ].each do |path|
        File.should_receive(:expand_path).once.ordered.with(path).and_return(path)
      end

      @ralf.local_log_dirname('bucket1', "log/access_log-").should  eql(bucket1_path)
      @ralf.local_log_dirname('bucket2', "log/").should  eql(bucket2_path)
    end

    xit "should save to a subdir when a output_dir_format is given" do
      path1 = '/Test/Users/test_user/S3/bucket1/log/2010/02/10'
      File.should_receive(:expand_path).once.with(path1).and_return(path1)

      @ralf.local_log_dirname('bucket1', "log/access_log-").should  eql(path1)

      path2 = '/Test/Users/test_user/S3/bucket1/log/2010/w06'
      File.should_receive(:expand_path).once.with(path2).and_return(path2)

      @ralf.output_dir_format = ':year/w:week'
      @ralf.local_log_dirname('bucket1', "log/").should  eql(path2)
    end

    xit "should get the proper directories" do
      File.should_receive(:expand_path).with('/Test/Users/test_user/S3/bucket1/log/2010/02/10').and_return('/Test/Users/test_user/S3/bucket1/log/2010/02/10')
      File.should_receive(:join).any_number_of_times { |*args| args.join('/') }
      
      # @key1.should_receive(:name).and_return('log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT')
      @ralf.local_log_file_basename_prefix('log/access_log-').should eql('access_log-')
      @ralf.local_log_file_basename('log/access_log-', 'log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT').should eql('access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT')
      @ralf.local_log_dirname('bucket1', 'log/access_log-').should eql('/Test/Users/test_user/S3/bucket1/log/2010/02/10')

      # @key1.should_receive(:name).and_return('log/2010-02-10-00-05-32-ZDRFGTCKUYVJCT')
      @ralf.local_log_file_basename_prefix('log/').should   eql('')
      @ralf.local_log_file_basename('log/', 'log/2010-02-10-00-05-32-ZDRFGTCKUYVJCT').should   eql('2010-02-10-00-05-32-ZDRFGTCKUYVJCT')

      path = '/Test/Users/test_user/S3/bucket2/log/2010/02/10'
      File.should_receive(:expand_path).once.with(path).and_return(path)
      @ralf.local_log_dirname('bucket2', 'log/').should eql(path)
    end

  end

  describe "Conversion" do

    before(:each) do
      config_file_expectations
      
      @ralf    = Ralf.new(@valid_options)
      @bucket1 = mock('bucket1')
    end

    xit "should convert the alf to clf" do
      File.should_receive(:open).once.with("/Test/Users/test_user/S3/s3_combined_bucket1_2010-02-10.log", "w").and_return(File)
      File.should_receive(:open).once.with("/Test/Users/test_user/S3/s3_combined_bucket1_2010-02-10.alf", "r").and_return(File)
      File.should_receive(:close).once.and_return(true)

      File.should_receive(:join).any_number_of_times { |*args| args.join('/') }

      @bucket1.stub(:name).twice.and_return('bucket1')
      @ralf.convert_alf_to_clf(@bucket1).should eql(true)
    end

    xit "should find the proper values in a line" do
      [ [
        '2cf7e6b06335c0689c6d29163df5bb001c96870cd78609e3845f1ed76a632621 assets.staging.kerkdienstgemist.nl [10/Feb/2010:07:17:01 +0000] 10.32.219.38 3272ee65a908a7677109fedda345db8d9554ba26398b2ca10581de88777e2b61 784FD457838EFF42 REST.GET.ACL - "GET /?acl HTTP/1.1" 200 - 1384 - 399 - "-" "Jakarta Commons-HttpClient/3.0" -                        ',
        '10.32.219.38 - 3272ee65a908a7677109fedda345db8d9554ba26398b2ca10581de88777e2b61 [10/Feb/2010:07:17:01 +0000] "GET /?acl HTTP/1.1" 200 1384 "-" "Jakarta Commons-HttpClient/3.0"'
      ],[
        '2cf7e6b06335c0689c6d29163df5bb001c96870cd78609e3845f1ed76a632621 assets.staging.kerkdienstgemist.nl [10/Feb/2010:07:17:02 +0000] 10.32.219.38 3272ee65a908a7677109fedda345db8d9554ba26398b2ca10581de88777e2b61 6E239BC5A4AC757C SOAP.PUT.OBJECT logs/2010-02-10-07-17-02-F6EFD00DAB9A08B6 "POST /soap/ HTTP/1.1" 200 - 797 686 63 31 "-" "Axis/1.3" -',
        '10.32.219.38 - 3272ee65a908a7677109fedda345db8d9554ba26398b2ca10581de88777e2b61 [10/Feb/2010:07:17:02 +0000] "POST /soap/ HTTP/1.1" 200 797 "-" "Axis/1.3"'
      ],[
        '2cf7e6b06335c0689c6d29163df5bb001c96870cd78609e3845f1ed76a632621 assets.staging.kerkdienstgemist.nl [10/Feb/2010:07:24:40 +0000] 10.217.37.15 - 0B76C90B3634290B REST.GET.ACL - "GET /?acl HTTP/1.1" 307 TemporaryRedirect 488 - 7 - "-" "Jakarta Commons-HttpClient/3.0" -                                                                          ',
        '10.217.37.15 - - [10/Feb/2010:07:24:40 +0000] "GET /?acl HTTP/1.1" 307 488 "-" "Jakarta Commons-HttpClient/3.0"'
      ] ].each do |alf,clf|
        @ralf.translate_to_clf(alf).should eql(clf)
      end
    end

    xit "should mark invalid lines with '# ERROR: '" do
      @ralf.translate_to_clf('An invalid line in the logfile').should match(/^# ERROR/)
    end

  end
  
end
