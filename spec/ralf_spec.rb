require File.dirname(__FILE__) + '/spec_helper'

require 'ralf'

describe Ralf do

  before(:each) do
    @default_params = {:config => File.dirname(__FILE__) + '/fixtures/config.yaml', :date => '2010-02-10'}
  end

  it "should initialize properly" do
    ralf = Ralf.new(@default_params)
    ralf.class.should eql(Ralf)
  end

  describe "Preferences" do

    it "should raise an error when an nonexistent config file is given" do
      lambda {
        ralf = Ralf.new(:config => '~/a_non_existen_file.yaml')
      }.should  raise_error(Ralf::NoConfigFile)
    end

    it "should set the preferences" do
      ralf = Ralf.new(@default_params)
      ralf.config[:aws_access_key_id].should      eql('access_key')
      ralf.config[:aws_secret_access_key].should  eql('secret')
      ralf.config[:out_path].should               eql('/Users/berl/S3')
      # ralf.config.should eql({:aws_access_key_id => 'access_key', :aws_secret_access_key => 'secret'})
    end

    it "should look for default configurations" do
      File.should_receive(:expand_path).once.with('~/.ralf.yaml').and_return('/Users/berl/.ralf.yaml')
      File.should_receive(:expand_path).twice.with('/Users/berl/.ralf.yaml').and_return('/Users/berl/.ralf.yaml')
      File.should_receive(:expand_path).once.with('/etc/ralf.yaml').and_return('/etc/ralf.yaml')
      File.should_receive(:exists?).once.with('/etc/ralf.yaml').and_return(false)
      File.should_receive(:exists?).twice.with('/Users/berl/.ralf.yaml').and_return(true)
      YAML.should_receive(:load_file).with('/Users/berl/.ralf.yaml').and_return({
        :aws_access_key_id      => 'access_key',
        :aws_secret_access_key  => 'secret',
        :out_path               => '/Users/berl/S3',
        :out_prefix             => 's3_combined'
      })

      ralf = Ralf.new()
    end

    it "should use AWS credentials provided in ENV" do
      ENV['AWS_ACCESS_KEY_ID']     = 'access_key'
      ENV['AWS_SECRET_ACCESS_KEY'] = 'secret'
      File.should_receive(:exists?).once.with('/etc/ralf.yaml').and_return(false)
      File.should_receive(:exists?).once.with('/Users/berl/.ralf.yaml').and_return(false)

      lambda {
        Ralf.new(:out_path => '/Users/berl/S3')
      }.should_not raise_error(Ralf::ConfigIncomplete)

    end

  end

  describe "Date handling" do

    it "should set the date to today" do
      ralf = Ralf.new()
      date = Date.today
      ralf.date.should  eql("%4d-%02d-%02d" % [date.year, date.month, date.day])
    end

    it "should set the date to the date given" do
      ralf = Ralf.new(@default_params.merge(:date => '2010-02-01'))
      ralf.date.should  eql('2010-02-01')
    end

    it "should raise error when invalid date given" do
      lambda {
        ralf = Ralf.new(@default_params.merge(:date => 'someday'))
        ralf.date.should  be_nil
      }.should raise_error(ArgumentError, "invalid date")
    end

    xit "should accept a range of dates" do
      ralf = Ralf.new(@default_params.merge(:date => 'now'))
      ralf.date.should  be_nil
    end

    xit "should accept a month and convert it to a date" do
      ralf = Ralf.new(@default_params.merge(:date => 'januari'))
      ralf.date.should  be_nil
    end

  end

  describe "Handle Buckets" do

    before(:each) do
      @ralf = Ralf.new(@default_params)
      @bucket1 = {:name => 'bucket1'}
      @bucket1.should_receive(:logging_info).any_number_of_times.and_return({ :enabled => true, :targetprefix => "log/access_log-" })
      @bucket1.should_receive(:name).any_number_of_times.and_return('media.kerdienstgemist.nl')
      @bucket2 = {:name => 'bucket2'}
      @bucket2.should_receive(:logging_info).any_number_of_times.and_return({ :enabled => false, :targetprefix => "log/" })
      @bucket2.should_receive(:name).any_number_of_times.and_return('media.kerdienstgemist.nl')
    end

    it "should find buckets with logging enabled" do
      @ralf.s3.should_receive(:buckets).once.and_return([@bucket1, @bucket2])

      @ralf.find_buckets_with_logging.should  eql([@bucket1, @bucket2])
      @ralf.buckets_with_logging.should       eql([@bucket1])
    end

    it "should save logging to disk" do
      @key1 = {:name => 'log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT', :data => 'This is content'}
      @key2 = {:name => 'log/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH', :data => 'This is content'}
      @bucket1.should_receive(:keys).any_number_of_times.and_return([@key1, @key2])
      @key1.should_receive(:name).any_number_of_times.and_return(@key1[:name])
      @key2.should_receive(:name).any_number_of_times.and_return(@key2[:name])
      @key1.should_receive(:data).any_number_of_times.and_return(@key1[:data])
      @key2.should_receive(:data).any_number_of_times.and_return(@key2[:data])
      File.should_receive(:makedirs).twice.with('/Users/berl/S3/media.kerdienstgemist.nl/log').and_return(true)
      File.should_receive(:exists?).twice.and_return(false, true)
      File.should_receive(:open).once.with('/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT', "w").and_return(true)

      @ralf.save_logging_to_disk(@bucket1).should eql([@key1, @key2])
    end

    it "should merge all logs" do
      out_string = StringIO.new

      Dir.should_receive(:glob).with('/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10*').and_return(
          ['/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT',
           '/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH'])

      File.should_receive(:open).with('/Users/berl/S3/s3_combined_media.kerdienstgemist.nl_2010-02-10.alf', "w").and_yield(out_string)

      LogMerge::Merger.should_receive(:merge).with(
        out_string, 
        '/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10-00-05-32-ZDRFGTCKUYVJCT',
        '/Users/berl/S3/media.kerdienstgemist.nl/log/access_log-2010-02-10-00-07-28-EFREUTERGRSGDH'
      )

      @ralf.merge_to_combined(@bucket1)

      out_string.string.should eql('')
    end

    it "should save logs which have a targetprefix containing a '/'" do
      @ralf.local_log_dirname(@bucket1).should  eql('/Users/berl/S3/media.kerdienstgemist.nl/log')
      @ralf.local_log_dirname(@bucket2).should  eql('/Users/berl/S3/media.kerdienstgemist.nl/log')
    end

  end

  describe "Conversion" do

    before(:each) do
      @ralf = Ralf.new(@default_params)
      @bucket1 = {:name => 'bucket1'}
      @bucket1.should_receive(:name).any_number_of_times.and_return('media.kerdienstgemist.nl')
    end

    it "should convert the alf to clf" do
      File.should_receive(:open).once.with("/Users/berl/S3/s3_combined_media.kerdienstgemist.nl_2010-02-10.log", "w").and_return(File)
      File.should_receive(:open).once.with("/Users/berl/S3/s3_combined_media.kerdienstgemist.nl_2010-02-10.alf", "r").and_return(File)
      File.should_receive(:close).once.and_return(true)
      @ralf.convert_alt_to_clf(@bucket1).should eql(true)
    end

    it "should find the proper values in a line" do
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

    it "should mark invalid lines with '# ERROR: '" do
      @ralf.translate_to_clf('An invalid line in the logfile').should match(/^# ERROR/)
    end

  end

end
