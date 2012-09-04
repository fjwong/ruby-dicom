# encoding: UTF-8

# This file contains extensions to the Ruby library which are used by Ruby DICOM.

# Extension to the String class. These mainly facilitate the processing and analysis of element tags.
# A tag string (as used by the ruby-dicom library) is 9 characters long and of the form 'GGGG,EEEE'
# (where G represents a group hexadecimal, and E represents an element hexadecimal).
#
class String

  # Renames the original unpack method.
  #
  alias __original_unpack__ unpack

  # Checks if a string value LOOKS like a DICOM name - it may still not be valid one.
  #
  # @return [Boolean] true if a string looks like a DICOM name, and false if not
  #
  def dicom_name?
    self == self.dicom_titleize
  end

  # Checks if a string value LOOKS like a DICOM method name - it may still not be valid one.
  #
  # @return [Boolean] true if a string looks like a DICOM method name, and false if not
  #
  def dicom_method?
    self == self.dicom_underscore
  end

  # Capitalizes all the words in the string and replaces some characters to make a nicer looking title.
  #
  # @return [String] a formatted, capitalized string
  #
  def dicom_titleize
    self.dicom_underscore.gsub(/_/, ' ').gsub(/\b('?[a-z])/) { $1.capitalize }
  end

  # Makes an underscored, lowercased version of the string.
  #
  # @return [String] an underscored, lower case string
  #
  def dicom_underscore
    word = self.dup
    word.tr!('-', '_')
    word.downcase!
    word
  end

  # Divides a string into a number of sub-strings of exactly equal length.
  #
  # @note The length of self must be a multiple of parts, or an exception will be raised.
  # @param [Integer] parts the number of sub-strings to create
  # @return [Array<String>] the divided sub-strings
  #
  def divide(parts)
    raise ArgumentError, "Expected an integer (Fixnum). Got #{parts.class}." unless parts.is_a?(Fixnum)
    raise ArgumentError, "Argument must be in the range <1 - self.length (#{self.length})>. Got #{parts}." if parts < 1 or parts > self.length
    raise ArgumentError, "Length of self (#{self.length}) must be a multiple of parts (#{parts})." unless (self.length/parts).to_f == self.length/parts.to_f
    if parts > 1
      sub_strings = Array.new
      sub_length = self.length/parts
      parts.times { sub_strings << self.slice!(0..(sub_length-1)) }
      return sub_strings
    else
      return [self]
    end
  end

  # Extracts the element part of the tag string: The last 4 characters.
  #
  # @return [String] the element part of the tag
  #
  def element
    return self[5..8]
  end

  # Returns the group part of the tag string: The first 4 characters.
  #
  # @return [String] the group part of the tag
  #
  def group
    return self[0..3]
  end

  # Returns the "Group Length" ('GGGG,0000') tag which corresponds to the original tag/group string.
  # The original string may either be a 4 character group string, or a 9 character custom tag.
  #
  # @return [String] a group length tag
  #
  def group_length
    if self.length == 4
      return self + ',0000'
    else
      return self.group + ',0000'
    end
  end

  # Checks if the string is a "Group Length" tag (its element part is '0000').
  #
  # @return [Boolean] true if it is a group length tag, and false if not
  #
  def group_length?
    return (self.element == '0000' ? true : false)
  end

  # Checks if the string is a private tag (has an odd group number).
  #
  # @return [Boolean] true if it is a private tag, and false if not
  #
  def private?
    return ((self.upcase =~ /\A\h{3}[1,3,5,7,9,B,D,F],\h{4}\z/) == nil ? false : true)
  end

  # Checks if the string is a valid tag (as defined by ruby-dicom: 'GGGG,EEEE').
  #
  # @return [Boolean] true if it is a valid tag, and false if not
  #
  def tag?
    # Test that the string is composed of exactly 4 HEX characters, followed by a comma, then 4 more HEX characters:
    return ((self.upcase =~ /\A\h{4},\h{4}\z/) == nil ? false : true)
  end

  # Converts the string to a proper DICOM element method name symbol.
  #
  # @return [Symbol] a DICOM element method name
  #
  def to_element_method
    self.gsub(/^3/,'three_').gsub(/[#*?!]/,' ').gsub(', ',' ').gsub('&','and').gsub(' - ','_').gsub(' / ','_').gsub(/[\s\-\.\,\/\\]/,'_').gsub(/[\(\)\']/,'').gsub(/\_+/, '_').downcase.to_sym
  end

  # Redefines the core library unpack method, adding
  # the ability to decode signed integers in big endian.
  #
  # @param [String] format a format string which decides the decoding scheme to use
  # @return [Array<String, Integer, Float>] the decoded values
  #
  def unpack(format)
    # Check for some custom unpack strings that we've invented:
    case format
      when "k*" # SS
        # Unpack BE US, repack LE US, then finally unpack LE SS:
        wrongly_unpacked = self.__original_unpack__('n*')
        repacked = wrongly_unpacked.__original_pack__('S*')
        correct = repacked.__original_unpack__('s*')
      when 'r*' # SL
        # Unpack BE UL, repack LE UL, then finally unpack LE SL:
        wrongly_unpacked = self.__original_unpack__('N*')
        repacked = wrongly_unpacked.__original_pack__('I*')
        correct = repacked.__original_unpack__('l*')
      else
        # Call the original method for all other (normal) cases:
        self.__original_unpack__(format)
    end
  end

end


# Extensions to the Array class.
# These mainly deal with encoding integer arrays as well as conversion between
# signed and unsigned integers.
#
class Array

  # Renames the original pack method.
  #
  alias __original_pack__ pack

  # Redefines the old pack method, adding the ability to encode signed integers in big endian
  # (which surprisingly has not been supported out of the box in Ruby until version 1.9.3).
  #
  # @param [String] format a format string which decides the encoding scheme to use
  # @return [String] the encoded binary string
  #
  def pack(format)
    # FIXME: At some time in the future, when Ruby 1.9.3 can be set as required ruby version,
    # this custom pack (as well as unpack) method can be discarded, and the desired endian
    # encodings can probably be achieved with the new template strings introduced in 1.9.3.
    #
    # Check for some custom pack strings that we've invented:
    case format
      when 'k*' # SS
        # Pack LE SS, re-unpack as LE US, then finally pack BE US:
        wrongly_packed = self.__original_pack__('s*')
        reunpacked = wrongly_packed.__original_unpack__('S*')
        correct = reunpacked.__original_pack__('n*')
      when 'r*' # SL
        # Pack LE SL, re-unpack as LE UL, then finally pack BE UL:
        wrongly_packed = self.__original_pack__('l*')
        reunpacked = wrongly_packed.__original_unpack__('I*')
        correct = reunpacked.__original_pack__('N*')
      else
        # Call the original method for all other (normal) cases:
        self.__original_pack__(format)
    end
  end

  # Packs an array of (unsigned) integers to a binary string (blob).
  #
  # @param [Integer] depth the bit depth to be used when encoding the unsigned integers
  # @return [String] an encoded binary string
  #
  def to_blob(depth)
    raise ArgumentError, "Expected Integer, got #{depth.class}" unless depth.is_a?(Integer)
    raise ArgumentError, "Unsupported bit depth #{depth}." unless [8,16].include?(depth)
    case depth
    when 8
      return self.pack('C*') # Unsigned char
    when 16
      return self.pack('S*') # Unsigned short, native byte order
    end
  end

  # Shifts the integer values of the array to make a signed data set.
  # The size of the shift is determined by the given bit depth.
  #
  # @param [Integer] depth the bit depth of the integers
  # @return [Array<Integer>] an array of signed integers
  #
  def to_signed(depth)
    raise ArgumentError, "Expected Integer, got #{depth.class}" unless depth.is_a?(Integer)
    raise ArgumentError, "Unsupported bit depth #{depth}." unless [8,16].include?(depth)
    case depth
    when 8
      return self.collect {|i| i - 128}
    when 16
      return self.collect {|i| i - 32768}
    end
  end

  # Shifts the integer values of the array to make an unsigned data set.
  # The size of the shift is determined by the given bit depth.
  #
  # @param [Integer] depth the bit depth of the integers
  # @return [Array<Integer>] an array of unsigned integers
  #
  def to_unsigned(depth)
    raise ArgumentError, "Expected Integer, got #{depth.class}" unless depth.is_a?(Integer)
    raise ArgumentError, "Unsupported bit depth #{depth}." unless [8,16].include?(depth)
    case depth
    when 8
      return self.collect {|i| i + 128}
    when 16
      return self.collect {|i| i + 32768}
    end
  end

end