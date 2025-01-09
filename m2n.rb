#!/usr/bin/env ruby
#
# m2n.rb: Mail ni Nankasuru
#    written by K.Sasada
#
require 'uri'
require 'socket'
require 'optparse'
require 'net/smtp'
require 'logger'
require 'fileutils'
require 'tempfile'

# 1.9 compatible
unless ''.respond_to? :each
  class String
    def each
      yield self
    end
  end
end

module M2N
  REVISION = '$Revision: 6 $'
  DATE = '$Date: 2007-07-20 21:59:35 +0900 (Fri, 20 Jul 2007) $'
  VERSION = "m2n 0.3 (#{REVISION}, #{DATE})"

  #
  # Rule class
  #
  class Rule
    Rules = []

    #
    # Add a rule.
    #
    def self.add header, pattern, block
      Rules << Rule.new(header, pattern, block)
    end

    #
    # Clear all rules.
    #
    def self.clear
      Rules.clear
    end

    #
    # Apply rules on mail.
    #
    def self.kick mail
      begin
        Rules.each{|rule|
          break if rule.exec mail
        }
      rescue Exception
        mail.save
        raise
      end
    end

    #
    # Initializer.
    #
    def initialize header, pattern, block
      @header = header
      @pattern = pattern
      @block = block
    end

    #
    # Execute this rule with mail.
    #
    def exec mail
      if @header
        @header.each{|h|
          if match = @pattern.match(mail[h])
            log "match: #{match.to_a.inspect} - #{mail}" if $DEBUG || $m2n_test
            # return true if $m2n_test
            mail.search_header = h
            mail.search_result = match

            case @block.call(mail)
            when :through
              mail.search_header = nil
              mail.search_result = nil
              return false
            else
              return true
            end
          end
        }
      else
        log "all match: #{mail}" if $DEBUG || $m2n_test
        # return true if $m2n_test
        return @block.call(mail) != :through
      end

      false
    end
  end

  #
  # Mail body.
  #
  class Mail

    #
    # initialize
    #
    def initialize path = nil
      if path
        @path = path
        @temp = false
        @file = File.basename(path)
        body = File.readlines(path)
      else
        hostname = Socket.gethostname
        @file = "#{Time.now.to_i}.#{$$}.#{hostname}"
        @temp = Tempfile.open(@file)
        @path = @temp.path
        @temp.write((body = STDIN.readlines).join)
        @temp.close
      end

      @header = {}
      @header_keys = []
      @body = []

      begin
        while line = body.shift.scrub
          next if /^From / =~ line # skip From-line
          break if /^$/=~line	   # end of header
          if /^(\S+?):\s*(.*)/ =~ line
            attr = add_header($1, $2)
          else
            @header[attr].last << "\n#{line.chomp}"
          end
        end
        @body = body.join
      rescue Exception
        save
        raise
      end

      @search_header = nil
      @search_result = nil
    end

    attr_accessor :search_header, :search_result
    attr_reader   :path

    ##
    ## sending mail utilities
    ##
    
    #
    # Sending mail utility method.
    #
    def self.send from_addr, to_addr, message
      Net::SMTP.start(::SMTP_HOST, ::SMTP_PORT) {|smtp|
        smtp.send_mail message, from_addr, to_addr
      }
    end

    #
    # Send this mail to addr.
    #
    def send_to to_addr = nil, from_addr = nil
      unless $m2n_test
        Mail.send(from_addr || self['From'], to_addr || self['To'], self.text)
      end
      mlog("sent to #{to_addr}")
    end

    ##
    ## rule utilities
    ##
    
    #
    # Discard this message.
    #
    def discard
      if @temp
        FileUtils.rm(@path) unless $m2n_test
        @path = nil
      end
      mlog("discarded")
    end

    #
    # Move this message to folder.
    #
    def move_to folder
      folder = imap_folder_name(folder)
      path = File.join(imap_folder2path(folder), @file)
      unless $m2n_test
        FileUtils.cp(@path, path)
        FileUtils.rm(@path)
        @path = path
      end
      mlog("moved to #{path}")
    end

    #
    # Execute command with mail body
    #
    def exec cmd, *args
      cmd = [cmd, *args].join(' ')

      if $m2n_test
        log "exec: test (#{cmd})"
      else
        r = system(cmd)
        if r
          log "exec: done (#{cmd})"
        else
          log "exec: failed #{$?} (#{cmd})"
        end
      end
    end

    #
    # log output with mail information
    #
    def mlog action
      message = LOGFORMAT.gsub(/\$\{(.+?)\}/){
        case $1
        when 'Action'
          action
        else
          self[$1]
        end
      }
      log(message)
    end

    ##
    ## Mail contents utilities
    ##

    #
    # Full text of this message.
    #
    def text
      File.read(@path)
    end

    #
    # access header information.
    #
    def [](k)
      (@header[k.capitalize] || []).first
    end

    #
    # add a header.
    #
    def add_header k, v
      attr = k.capitalize
      if @header[attr]
        @header[attr] << [v]
      else
        @header_keys << k
        @header[attr] = [v]
      end
      attr
    end

    #
    # set header information.  this change doesn't effect until commit.
    #
    def []=(k, v)
      if v
        @header_keys << k unless @header[k.capitalize]
        @header[k.capitalize] = [v]
      else
        @header.delete k.capitalize
      end
    end

    def header=(h)
      @header = {}
      @header_keys = []
      h.each{|k, v|
        add_header k, v
      }
    end

    #
    # get mail body
    #
    def body
      @body
    end

    #
    # set mail body
    #
    def body=(v)
      @body = v
    end

    #
    # commit changes to file
    #
    def commit
      @temp = Tempfile.open(@file)
      @path = @temp.path

      @header_keys.each{|k|
        vs = @header[k.capitalize]
        vs.each{|v|
          @temp.puts "#{k}: #{v}"
        } if vs
      }

      @temp.puts # sep
      @temp.puts @body
      @temp.close
    end

    #
    # Save this mail on HOME to rescue.
    #
    def save
      if @temp
        path = File.join(File.expand_path('~'), "m2n-saved-#{@file}")
        mlog("saved to #{path}")
        FileUtils.cp(@path, path)
      end
    end

    #
    # Inspector
    #
    def to_s
      "<mail message - From: #{self['From']}, To: #{self['To']}, Subject: #{self['Subject']}>"
    end

    def folder_name folder
      File.basename(imap_folder_name(folder))
    end

    #######################################################
    private

    #
    # import from net/imap.rb
    #
    def encode_imapfolder(s)
      return s.gsub(/(&)|([^\x20-\x25\x27-\x7e]+)/n) { |x|
        if $1
          "&-"
        else
          base64 = [x.unpack("U*").pack("n*")].pack("m")
          "&" + base64.delete("=\n").tr("/", ",") + "-"
        end
      }
    end

    $m2n_makedir_hook = nil
    #
    # prepare Maildir for imap and return file path
    #
    def imap_folder2path folder
      path = File.expand_path(File.join(MAILDIR, encode_imapfolder(folder.tr('/', '.'))))

      if !test(?d, path)
        log("create directory: #{path}")
        unless $m2n_test
          $m2n_makedir_hook.call(path) if $m2n_makedir_hook
          FileUtils.mkdir_p(path)
          FileUtils.mkdir(File.join(path, "cur"))
          FileUtils.mkdir(File.join(path, "new"))
          FileUtils.mkdir(File.join(path, "tmp"))
        end
      end

      File.join(path, '/new')
    end

    #
    # imap_folder_name
    #
    def imap_folder_name folder
      if @search_result
        folder = folder.gsub(/\$\{(.)\}/){
          sig = $1
          case sig
          when 'h'
            self[@search_header]
          when /[0-9]/
            @search_result[sig.to_i]
          else
            '__bug__'
          end.tr('.', '_')
        }
      end

      unless folder
        folder = ''
      end

      folder
    end
  end

  ####

  #
  # Load configuration.
  #
  def self.load_config file
    load file

    # set default value
    {
      :SMTP_HOST => 'localhost',
      :SMTP_PORT => 25,
      :LOG_FILE  => File.join(File.dirname(file), "#{Time.now.strftime('%Y-%m-%d')}.log"),
      :LOGFORMAT => "${Action}\n  From: ${From}, To: ${To}\n  Subject: ${Subject}",
      :MAILDIR   => '~/Maildir',
    }.each{|k, v|
      Object.const_defined?(k) ? nil : Object.const_set(k, v)
    }

    # open log file
    $m2n_logger = Logger.new(File.expand_path(::LOG_FILE)) unless $m2n_logger

    # add default rule
    rule_mv
  end

  #
  # Parse option
  #
  def self.parse_option args
    rcfile = '~/.m2n/m2nrc'

    $m2n_test = false
    $m2n_logger = false
    $m2n_remove_when_move = false

    parser = OptionParser.new{|o|
      o.banner = "Usage: ruby #{$0} [options]"
      o.separator ""
      o.separator "Optional:"

      o.on("-r", "--rc [RCFILE]", "Specify rcfile"){|f|
        rcfile = f
      }

      o.on("-d", "--debug", "Debug mode"){
        require 'pp'
        $m2n_logger = Logger.new(STDOUT)
        $DEBUG = true
      }
      o.on("-t", "--test", "Test mode (do not touch any file)"){
        require 'pp'
        $m2n_logger = Logger.new(STDOUT)
        $m2n_test = true
      }

      o.on_tail("-h", "--help", "Show this message"){
        puts M2N::VERSION
        puts o
        exit
      }
      o.on_tail("-v", "--version", "Show version"){
        puts M2N::VERSION
        exit
      }
    }

    parser.parse!(ARGV)
    load_config rcfile
  end

  #
  # m2n main process.
  #
  def self.main args
    mail = parse_option(args)

    if ARGV.empty?
      Rule.kick Mail.new
    else
      ARGV.each{|path|
        if FileTest.directory?(path)
          Dir.glob(File.join(path, '*')){|file|
            Rule.kick(Mail.new(file))
          }
        else
          Rule.kick(Mail.new(path))
        end
      }
    end
  end
end

#
# rule constructor
#
def rule header = nil, pattern = nil, &b
  M2N::Rule.add(header, pattern, b)
end

#
# custom rule: move
#
def rule_mv header = nil, pattern = nil, folder = nil
  rule(header, pattern){|mail|
    yield mail if block_given?
    mail.move_to(folder)
  }
end

#
# custom rule: discard
#
def rule_discard header, pattern
  rule(header, pattern){|mail|
    yield mail if block_given?
    mail.discard
  }
end

#
# Log output function
#
def log message
  $m2n_logger.info(message)
end

#
# Error Log output function
#
def elog message
  if $m2n_logger
    $m2n_logger.error(message)
  else
    puts message
  end
end

if $0 == __FILE__
  #
  # Work as Application.
  #
  begin
    M2N::main(ARGV)
  rescue SystemExit, Interrupt
    # ignore
  rescue Exception => e
    elog("#{e.class}: #{e.message}\n  #{e.backtrace.join("\n  ")}")
    exit 0 ###
  end
end

