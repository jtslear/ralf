require 'spec_helper'
require 'ralf'

describe Ralf do

  describe "#read_config" do
    before do
      File.should_receive(:open).with('./ralf.conf').and_return(StringIO.new('option: value'))
    end
    it "reads the config" do
      subject.read_config('./ralf.conf').should be_true
    end
    it "sets the @config with symbolized keys" do
      subject.read_config('./ralf.conf').should be_true
      subject.config.should eql({:option => "value"})
    end
  end

  describe "#validate_config" do
    it "raises InvalidConfig if no config is set" do
      lambda {
        subject.validate_config
      }.should raise_error(Ralf::InvalidConfig, "No config set")
    end
    it "raises InvalidConfig if minimal required options are not set" do
      subject.stub(:config).and_return({})
      lambda {
        subject.validate_config
      }.should raise_error(Ralf::InvalidConfig, "Required options: 'cache_dir', 'output_dir', 'days_to_look_back', 'days_to_ignore', 'aws_key', 'aws_secret', 'log_buckets', 'log_prefix'")
    end
    it "does not raise errors when minimal required options are set" do
      subject.stub(:config).and_return({
        :cache_dir  => './cache',
        :output_dir => './logs/:year/:month/:day',
        :days_to_look_back => 5,
        :days_to_ignore => 2,
        :aws_key    => '--AWS_KEY--',
        :aws_secret => '--AWS_SECTRET--',
        :log_buckets => ["logbucket1", "logbucket2"],
        :log_prefix => 'logs/'
      })
      File.should_receive(:exist?).with('./cache').and_return(true)
      lambda {
        subject.validate_config
      }.should_not raise_error
    end
    it "raises error if cache_dir does not exists" do
      subject.stub(:config).and_return({
        :cache_dir  => './cache',
        :output_dir => './logs/:year/:month/:day',
        :days_to_look_back => 5,
        :days_to_ignore => 2,
        :aws_key    => '--AWS_KEY--',
        :aws_secret => '--AWS_SECTRET--',
        :log_buckets => ["logbucket1", "logbucket2"],
        :log_prefix => 'logs/'
      })
      File.should_receive(:exist?).with('./cache').and_return(false)
      lambda {
        subject.validate_config
      }.should raise_error(Ralf::InvalidConfig, "Required options: 'Cache dir does not exixst'")
    end
  end

  describe "#initialize_s3" do
    it "sets @s3" do
      subject.stub(:config).and_return({
        :aws_key    => '--AWS_KEY--',
        :aws_secret => '--AWS_SECTRET--'
      })
      subject.initialize_s3
      subject.s3.should_not be_nil
    end
  end

  describe "#iterate_and_process_log_buckets" do
    it "iterates over configured log_buckets" do
      subject.stub(:config).and_return({:log_buckets => ['berl-log']})
      s3_bucket_mock = mock(RightAws::S3::Bucket)
      subject.stub(:s3).and_return(mock(RightAws::S3, :bucket => s3_bucket_mock))
      processor = mock(Ralf::BucketProcessor)
      processor.should_receive(:process)
      Ralf::BucketProcessor.should_receive(:new).and_return(processor)

      subject.iterate_and_process_log_buckets
    end
  end

end