require 'serialport'
require 'sphero/request'
require 'sphero/response'
require 'thread'

class Sphero
  VERSION = '1.1.6'

  FORWARD = 0
  RIGHT = 90
  BACKWARD = 180
  LEFT = 270

  attr_accessor :connection_types, :async_responses

  class << self
    def start(dev, &block)
      sphero = self.new dev
      if (block_given?)
        begin
           sphero.instance_eval(&block)
        ensure
           sphero.close
        end
        return nil
      end
      return sphero
    rescue Errno::EBUSY
      retry
    end
  end

  def initialize dev
    initialize_serialport dev
    @dev  = 0x00
    @seq  = 0x00
    @lock = Mutex.new
    @async_responses = []
  end
  
  def close
    @lock.synchronize do
      @sp.close
    end
  end

  def ping
    write Request::Ping.new(@seq)
  end

  def version
    write Request::GetVersioning.new(@seq)
  end

  def bluetooth_info
    write Request::GetBluetoothInfo.new(@seq)
  end

  def auto_reconnect= time_s
    write Request::SetAutoReconnect.new(@seq, time_s)
  end

  def auto_reconnect
    write(Request::GetAutoReconnect.new(@seq)).time
  end

  def disable_auto_reconnect
    write Request::SetAutoReconnect.new(@seq, 0, 0x00)
  end

  def power_state
    write Request::GetPowerState.new(@seq)
  end

  def sphero_sleep wakeup = 0, macro = 0
    write Request::Sleep.new(@seq, wakeup, macro)
  end

  def roll speed, heading, state = true
    write Request::Roll.new(@seq, speed, heading, state ? 0x01 : 0x00)
  end

  def stop
    roll 0, 0
  end

  def heading= h
    write Request::Heading.new(@seq, h)
  end

  def rgb r, g, b, persistant = false
    write Request::SetRGB.new(@seq, r, g, b, persistant ? 0x01 : 0x00)
  end

  # This retrieves the "user LED color" which is stored in the config block
  # (which may or may not be actively driven to the RGB LED).
  def user_led
    write Request::GetRGB.new(@seq)
  end

  # Brightness 0x00 - 0xFF
  def back_led_output= h
    write Request::SetBackLEDOutput.new(@seq, h)
  end

  # Rotation Rate 0x00 - 0xFF
  def rotation_rate= h
    write Request::SetRotationRate.new(@seq, h)
  end

  # just a nicer alias for Ruby's own sleep
  def keep_going(duration)
    Kernel::sleep duration
  end

  # configure collision detection messages
  def configure_collision_detection meth, x_t, y_t, x_spd, y_spd, dead
    write Request::ConfigureCollisionDetection.new(@seq, meth, x_t, y_t, x_spd, y_spd, dead)
  end

  # read all outstanding async packets and store in async_responses
  # would not do well to receive simple responses this way...
  def read_async_messages
    header, body = nil
    new_responses = []

    @lock.synchronize do
      header, body = read_next_response

      while header && Response.async?(header)
        new_responses << Response::AsyncResponse.response(header, body)
        header, body = read_next_response
      end
    end
    
    async_responses.concat(new_responses) unless new_responses.empty?
    return !new_responses.empty?
  end

  private
  
  def is_windows?
    os = RUBY_PLATFORM.split("-")[1]
    if (os == 'mswin' or os == 'bccwin' or os == 'mingw' or os == 'mingw32')
      true
    else
      false
    end
  end

  def initialize_serialport dev
    @sp = SerialPort.new dev, 115200, 8, 1, SerialPort::NONE
    if is_windows?
      @sp.read_timeout=1000
      @sp.write_timeout=0
      @sp.initial_byte_offset=5
    end
  end

  def write packet
    header, body = nil

    @lock.synchronize do
      @sp.write packet.to_str
      @seq += 1

      # pick off asynch packets and store, till we get to the message response
      header, body = read_next_response(true)
      while header && Response.async?(header)
        async_responses << Response::AsyncResponse.response(header, body)
        header, body = read_next_response
      end
    end
    
    response = packet.response header, body

    if response.success?
      response
    else
      raise response
    end
  end

  def read_next_response(blocking=false)
    header, body = nil

    begin
      if blocking
        header = @sp.read(5).unpack 'C5'
      else
        header = @sp.read_nonblock(5).unpack 'C5'
      end
      body  = @sp.read header.last
    rescue IO::WaitReadable # raised by read_response when no data for non-blocking read
      return nil, nil
      # TODO: handle other exceptions
    end

    return header, body
  end
end

