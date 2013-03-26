require 'spec_helper'
require 'ralf'

describe Ralf::BucketProcessor do

  before do
    @s3_bucket_mock = mock(RightAws::S3::Bucket, :name => "logfilebucket")
    @ralf = mock(Ralf, :config => {
      :cache_dir  => './logs/cache/:bucket',
      :output_dir => './logs/:bucket/:year/:month',
      :day_file   => './logs/:bucket/:year/:month/:day.log',
      :month_file => './logs/:bucket/:year/:month/combined.log',
      :log_prefix => 'logs/',
      :days_to_look_back => 3,
      :days_to_ignore => 1,
      :recalculate_partial_content => true
    })
  end

  describe "#initialize" do
    it "needs an S3 bucket and a config hash" do
      lambda {
        Ralf::BucketProcessor.new(@s3_bucket_mock, @ralf)
      }.should_not raise_error
    end
  end

  describe "with an initalized object" do
    subject { Ralf::BucketProcessor.new(@s3_bucket_mock, @ralf) }
    describe "#process_keys_for_range" do
      it "retrieve the keys in the range" do
        Date.stub(:today).and_return(Date.new(2013, 2, 13))
        subject.should_receive(:process_keys_for_date).with(Date.new(2013, 2, 11))
        subject.should_receive(:process_keys_for_date).with(Date.new(2013, 2, 12))
        subject.should_receive(:process_keys_for_date).with(Date.new(2013, 2, 13))
        subject.process_keys_for_range
      end
    end
    describe "#process_keys_for_date" do
      it "finds all keys for date" do
        key_mock1 = mock(RightAws::S3::Key, :name => 'logs/2013-02-11-00-05-23-UYVJCTKCTGFRDZ')
        key_mock2 = mock(RightAws::S3::Key, :name => 'logs/2013-02-12-00-23-05-CVJCTZDRFGTYUK')
        key_mock3 = mock(RightAws::S3::Key, :name => 'logs/2013-02-13-05-00-23-FGTCCJVYUKTRDZ')
        @s3_bucket_mock.should_receive(:keys).with({"prefix"=>"logs/2013-02-13"}).and_return([key_mock1, key_mock2, key_mock3])
        subject.should_receive(:download_key).with(key_mock1)
        subject.should_receive(:download_key).with(key_mock2)
        subject.should_receive(:download_key).with(key_mock3)
        subject.process_keys_for_date(Date.new(2013, 2, 13))
      end
      it "should return an array of filenames"
    end
    describe "#download_key" do
      before do
        @key_mock1 = mock(RightAws::S3::Key, :name => 'logs/2013-02-11-00-05-23-UYVJCTKCTGFRDZ', :data => 'AWS LOGLINE')
        subject.should_receive(:cache_dir).and_return('./logs/cache/logfilebucket/')
      end
      it "downloads key if it does not exists" do
        File.should_receive(:exist?).with('./logs/cache/logfilebucket/2013-02-11-00-05-23-UYVJCTKCTGFRDZ').and_return(false)
        File.should_receive(:open).with("./logs/cache/logfilebucket/2013-02-11-00-05-23-UYVJCTKCTGFRDZ", "w").and_yield(mock(File, :write => true))
        subject.download_key(@key_mock1)
      end
      it "skip download for key if it already exists in cache" do
        File.should_receive(:exist?).with('./logs/cache/logfilebucket/2013-02-11-00-05-23-UYVJCTKCTGFRDZ').and_return(true)
        File.should_not_receive(:open)
        subject.download_key(@key_mock1)
      end
    end
    describe "#merge" do
      it "reads all files from range into memory and sort it by timestamp" do
        subject.merge([
          'spec/fixtures/2012-06-04-17-15-58-41BB059FD94A4EC7',
          'spec/fixtures/2012-06-04-17-16-40-4E34CC5FF2B57639',
          'spec/fixtures/2013-03-24-11-17-27-ACFA8172D5374531',
        ]).collect {|l| l[:timestamp].to_s}.should eql([
          "2012-06-03T16:34:26+00:00",
          "2012-06-03T16:34:26+00:00",
          "2012-06-04T16:34:28+00:00",
          "2012-06-04T16:44:26+00:00",
          "2012-06-04T16:44:26+00:00",
          "2012-06-04T16:45:41+00:00",
          "2012-06-04T16:46:31+00:00",
          "2012-06-04T16:46:31+00:00",
          "2012-06-05T16:36:31+02:00",
          "2012-06-05T16:35:41+00:00",
        ])
      end
    end
    describe "#write_to_day_files" do
      it "writes to combined files in the subdirectories" do
        subject.stub(:ensure_output_directories).and_return(true)
        subject.stub(:open_file_descriptors).and_return(true)
        subject.stub(:close_file_descriptors).and_return(true)

        open_file_12 = StringIO.new
        open_file_13 = StringIO.new

        open_file_12.should_receive(:puts).twice.and_return(true)
        open_file_13.should_receive(:puts).and_return(true)

        subject.open_files["20130212"] = open_file_12
        subject.open_files["20130213"] = open_file_13

        subject.write_to_day_files([
          {:timestamp => Time.mktime(2013, 2, 11, 16, 34, 26, '+0000').utc   , :string => 'logfile_string'},
          {:timestamp => Time.mktime(2013, 2, 12, 16, 34, 26, '+0000').utc+10, :string => 'logfile_string'},
          {:timestamp => Time.mktime(2013, 2, 12, 16, 34, 26, '+0000').utc+15, :string => 'logfile_string'},
          {:timestamp => Time.mktime(2013, 2, 13, 16, 34, 26, '+0000').utc+23, :string => 'logfile_string'}
        ])
      end
    end
    describe "#ensure_output_directories" do
      before do
        subject.should_receive(:start_day).and_return(Date.new(2013, 2, 11))
        Date.should_receive(:today).and_return(Date.new(2013, 2, 13))
      end
      it "ensures that base dir exists" do
        FileUtils.should_receive(:mkdir_p).with('./logs/logfilebucket/2013/02').twice
        subject.ensure_output_directories
      end
      it "does not create other directories" do
        FileUtils.should_not_receive(:mkdir_p).with('./logs/logfilebucket/2013/01')
        FileUtils.should_not_receive(:mkdir_p).with('./logs/logfilebucket/2013/03')
        subject.ensure_output_directories
      end
    end
    describe "#open_file_descriptors" do
      before do
        subject.should_receive(:start_day).and_return(Date.new(2013, 2, 11))
        Date.should_receive(:today).and_return(Date.new(2013, 2, 13))
      end
      it "opens filedescriptors" do
        File.should_receive(:open).with('./logs/logfilebucket/2013/02/12.log', 'w')
        File.should_receive(:open).with('./logs/logfilebucket/2013/02/13.log', 'w')
        subject.open_file_descriptors
      end
      it "does nog open filedescriptors outside of the range" do
        File.should_not_receive(:open).with('./logs/logfilebucket/2013/02/11.log', 'w')
        File.should_not_receive(:open).with('./logs/logfilebucket/2013/02/14.log', 'w')
        subject.open_file_descriptors
      end
    end
    describe "#close_file_descriptors" do
      it "closes filedescriptors" do
        open_file = StringIO.new
        subject.stub(:open_files).and_return({"20130213" => open_file})
        open_file.should_receive(:close).and_return(true)
        subject.close_file_descriptors
      end
    end
    describe "#cache_dir" do
      it "interpolates the cache_dir" do
        File.should_receive(:exist?).with('cache/logfilebucket').and_return(true)
        subject.should_receive(:config).and_return({:cache_dir => 'cache/:bucket'})
        subject.cache_dir.should eql('cache/logfilebucket')
      end
      it "raises error if cache_dir does not exists" do
        lambda {
          subject.cache_dir
        }.should raise_error(Ralf::InvalidConfig, "Required options: 'Cache dir does not exixst'")
      end
    end
    describe "#date_range" do
      before do
        Date.stub(:today).and_return(Date.new(2013, 2, 4))
      end
      it "creates an array with dates" do
        subject.config[:days_to_look_back] = 8
        subject.config[:days_to_ignore] = 0
        subject.date_range.should eql([
          Date.new(2013, 1, 28),
          Date.new(2013, 1, 29),
          Date.new(2013, 1, 30),
          Date.new(2013, 1, 31),
          Date.new(2013, 2, 1),
          Date.new(2013, 2, 2),
          Date.new(2013, 2, 3),
          Date.new(2013, 2, 4)
        ])
      end
    end
    describe "#date_range_with_ignored_days" do
      before do
        Date.stub(:today).and_return(Date.new(2013, 2, 4))
      end
      it "substracts 2 dates from date_range" do
        subject.config[:days_to_look_back] = 8
        subject.config[:days_to_ignore] = 2
        subject.date_range_with_ignored_days.should eql([
          Date.new(2013, 1, 30),
          Date.new(2013, 1, 31),
          Date.new(2013, 2, 1),
          Date.new(2013, 2, 2),
          Date.new(2013, 2, 3),
          Date.new(2013, 2, 4)
        ])
      end
      it "substracts 4 dates from date_range" do
        subject.config[:days_to_look_back] = 8
        subject.config[:days_to_ignore] = 4
        subject.date_range_with_ignored_days.should eql([
          Date.new(2013, 2, 1),
          Date.new(2013, 2, 2),
          Date.new(2013, 2, 3),
          Date.new(2013, 2, 4)
        ])
      end
    end
    describe "#covered_months" do
      before do
        Date.stub(:today).and_return(Date.new(2013, 2, 4))
      end
      it "returns all months in range" do
        subject.config[:days_to_look_back] = 120
        subject.config[:days_to_ignore] = 4
        subject.covered_months.should eql([
          Date.new(2012, 10),
          Date.new(2012, 11),
          Date.new(2012, 12),
          Date.new(2013,  1),
          Date.new(2013,  2)
        ])
      end
      it "returns all months in selected range" do
        subject.config[:days_to_look_back] = 8
        subject.config[:days_to_ignore] = 4
        subject.covered_months.should eql([
          Date.new(2013,  1),
          Date.new(2013,  2)
        ])
      end
    end
    describe "#combine_day_files" do
      before do
        Date.stub(:today).and_return(Date.new(2013, 2, 4))
      end
      it "iterates over ordered input files and combines them" do
        combined_log = StringIO.new
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/combined.log', "w").and_return(combined_log)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/01.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/02.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/03.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/04.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/05.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/06.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/07.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/08.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/09.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/10.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/11.log').and_return(StringIO.new)
        File.should_receive(:open).ordered.with('./logs/logfilebucket/2013/02/12.log').and_return(StringIO.new)
        Dir.should_receive(:glob).with('./logs/logfilebucket/2013/02/[0-9][0-9].log').and_return([
          './logs/logfilebucket/2013/02/01.log',
          './logs/logfilebucket/2013/02/02.log',
          './logs/logfilebucket/2013/02/03.log',
          './logs/logfilebucket/2013/02/07.log',
          './logs/logfilebucket/2013/02/04.log',
          './logs/logfilebucket/2013/02/05.log',
          './logs/logfilebucket/2013/02/06.log',
          './logs/logfilebucket/2013/02/08.log',
          './logs/logfilebucket/2013/02/09.log',
          './logs/logfilebucket/2013/02/10.log',
          './logs/logfilebucket/2013/02/11.log',
          './logs/logfilebucket/2013/02/12.log',
        ])
        subject.combine_day_files #.should eql(['2013-01-01', '2013-02-01'])
      end
    end
  end
end

