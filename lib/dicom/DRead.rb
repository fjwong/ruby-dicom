#    Copyright 2008-2010 Christoffer Lervag

# Some notes about this DICOM file reading class:
# In addition to reading files that are compliant to DICOM 3 Part 10, the philosophy of this library
# is to have maximum compatibility, and as such it will read most 'DICOM' files that deviate from the standard.
# While reading files, this class will also analyse the hierarchy of elements for those DICOM files that
# feature sequences and items, enabling the user to take advantage of this information for advanced
# querying of the DICOM object afterwards.

module DICOM

  # The DRead class parses the DICOM data from a binary string.
  # The source of this binary string is typically either a DICOM file or a DICOM network transmission.
  #
  class DRead

    attr_reader :success, :obj, :explicit, :file_endian, :msg, :signature

    # Initializes a DRead instance.
    # Options: :bin.....etc
    #
    def initialize(obj, string=nil, options={})
      # Set the DICOM object as an instance variable:
      @obj = obj
      # Some of the options need to be transferred to instance variables:
      @transfer_syntax = options[:syntax]
      # Initiate the variables that are used during file reading:
      init_variables
      # Are we going to read from a file, or read from a binary string:
      if options[:bin]
        # Read from the provided binary string:
        @str = string
      else
        # Read from file:
        open_file(string)
        # Read the initial header of the file:
        if @file == nil
          # File is not readable, so we return:
          @success = false
          return
        else
          # Extract the content of the file to a binary string:
          @str = @file.read
          @file.close
        end
      end
      # Create a Stream instance to handle the decoding of content from this binary string:
      @stream = Stream.new(@str, @file_endian)
      # Do not check for header information when supplied a (network) binary string:
      unless options[:bin]
        # Read and verify the DICOM header:
        header = check_header
        # If the file didnt have the expected header, we will attempt to read
        # data elements from the very start file:
        if header == false
          @stream.skip(-132)
        elsif header == nil
          # Not a valid DICOM file, return:
          @success = false
          return
        end
      end
      # Run a loop which parses Data Elements, one by one, until the end of the data string is reached:
      data_element = true
      while data_element do
        # Using a rescue clause since processing Data Elements can cause errors when parsing an invalid DICOM string.
        begin
          # Extracting Data element information (nil is returned if end of file is encountered in a normal way).
          data_element = process_data_element
        rescue
          # The parse algorithm crashed. Set data_element to false to break the loop and toggle the success boolean to indicate failure.
          @msg << "Error! Failed to process a Data Element. This is probably the result of invalid or corrupt DICOM data."
          @success = false
          data_element = false
        end
      end
    end


    # Following methods are private:
    private


    # Checks for the official DICOM header signature.
    #
    def check_header
      # According to the official DICOM standard, a DICOM file shall contain 128 consequtive (zero) bytes,
      # followed by 4 bytes that spell the string 'DICM'. Apparently, some providers seems to skip this in their DICOM files.
      # Check that the file is long enough to contain a valid header:
      if @str.length < 132
        # This does not seem to be a valid DICOM file and so we return.
        return nil
      else
        @stream.skip(128)
        # Next 4 bytes should spell "DICM":
        identifier = @stream.decode(4, "STR")
        @header_length += 132
        if identifier != "DICM" then
          # Header signature is not valid (we will still try to read it is a DICOM file though):
          @msg << "Warning: The specified file does not contain the official DICOM header. Will try to read the file anyway, as some sources are known to skip this header."
          # As the file is not conforming to the DICOM standard, it is possible that it does not contain a
          # transfer syntax element, and as such, we attempt to choose the most probable encoding values here:
          @explicit = false
          return false
        else
          # Header signature is valid:
          @signature = true
          return true
        end
      end
    end

    # Governs the process of reading data elements from the DICOM file.
    # FIXME: This method has grown a bit messy and isn't very easy to follow. It would be nice if it could be cleaned up slightly.
    #
    def process_data_element
      #STEP 1:
      # Attempt to read data element tag:
      tag = read_tag
      # Return nil if we have (naturally) reached the end of the data string.
      return nil unless tag
      # STEP 2:
      # Access library to retrieve the data element name and VR from the tag we just read:
      # (Note: VR will be overwritten in the next step if the DICOM file contains VR (explicit encoding))
      name, vr = LIBRARY.get_name_vr(tag)
      # STEP 3:
      # Read VR (if it exists) and the length value:
      vr, length = read_vr_length(vr,tag)
      level_vr = vr
      # STEP 4:
      # Reading value of data element.
      # Special handling needed for items in encapsulated image data:
      if @enc_image and tag == ITEM_TAG
        # The first item appearing after the image element is a 'normal' item, the rest hold image data.
        # Note that the first item will contain data if there are multiple images, and so must be read.
        vr = "OW" # how about alternatives like OB?
        # Modify name of item if this is an item that holds pixel data:
        if @current_element.tag != PIXEL_TAG
          name = PIXEL_ITEM_NAME
        end
      end
      # Read the binary string of the element:
      bin = read_bin(length) if length > 0
      # Read the value of the element (if it contains data, and it is not a sequence or ordinary item):
      if length > 0 and vr != "SQ" and tag != ITEM_TAG
        # Read the element's processed value:
        value = read_value(vr, length)
      else
        # Data element has no value (data).
        value = nil
        # Special case: Check if pixel data element is sequenced:
        if tag == PIXEL_TAG
          # Change name and vr of pixel data element if it does not contain data itself:
          name = ENCAPSULATED_PIXEL_NAME
          level_vr = "SQ"
          @enc_image = true
        end
      end
      # Create an Element from the gathered data:
      if level_vr == "SQ" or tag == ITEM_TAG
        if level_vr == "SQ"
          # Create a Sequence:
          @current_element = Sequence.new(tag, :length => length, :name => name, :parent => @current_parent, :vr => vr)
        elsif tag == ITEM_TAG
          # Create an Item:
          if @enc_image
            @current_element = Item.new(tag, :bin => bin, :length => length, :name => name, :parent => @current_parent, :vr => vr)
          else
            @current_element = Item.new(tag, :length => length, :name => name, :parent => @current_parent, :vr => vr)
          end
        end
        # Common operations on the two types of parent elements:
        if length == 0 and @enc_image
          # Set as parent. Exceptions when parent will not be set:
          # Item/Sequence has zero length & Item is a pixel item (which contains pixels, not child elements).
          @current_parent = @current_element
        elsif length != 0
          @current_parent = @current_element unless name == PIXEL_ITEM_NAME
        end
        # If length is specified (no delimitation items), load a new DRead instance to read these child elements
        # and load them into the current sequence. The exception is when we have a pixel data item.
        if length > 0 and not @enc_image
          child_reader = DRead.new(@current_element, bin, :bin => true, :syntax => @transfer_syntax)
          @current_parent = @current_parent.parent
          @msg << child_reader.msg
          @success = child_reader.success
          return false unless @success
        end
      elsif DELIMITER_TAGS.include?(tag)
        # We do not create an element for the delimiter items.
        # The occurance of such a tag indicates that a sequence or item has ended, and the parent must be changed:
        @current_parent = @current_parent.parent
      else
        # Create an ordinary Data Element:
        @current_element = DataElement.new(tag, value, :bin => bin, :name => name, :parent => @current_parent, :vr => vr)
        # Check that the data stream didnt end abruptly:
        if length != @current_element.bin.length
          set_abrupt_error
          return false # (Failed)
        end
      end
      # Return true to indicate success:
      return true
    end

    # Reads and returns the data element's TAG (4 first bytes of element).
    #
    def read_tag
      tag = @stream.decode_tag
      if tag
        # When we shift from group 0002 to another group we need to update our endian/explicitness variables:
        if tag.group != META_GROUP and @switched == false
          switch_syntax
          # We may need to read our tag again if endian has switched (in which case it has been misread):
          if @switched_endian
            @stream.skip(-4)
            tag = @stream.decode_tag
          end
        end
      end
      return tag
    end

    # Reads and returns data element VR (2 bytes) and data element LENGTH (Varying length; 2-6 bytes).
    #
    def read_vr_length(vr, tag)
      # Structure will differ, dependent on whether we have explicit or implicit encoding:
      reserved = 0
      bytes = 0
      # *****EXPLICIT*****:
      if @explicit == true
        # Step 1: Read VR, 2 bytes (if it exists - which are all cases except for the item related elements)
        vr = @stream.decode(2, "STR") unless ITEM_TAGS.include?(tag)
        # Step 2: Read length
        # Three possible structures for value length here, dependent on element vr:
        case vr
          when "OB","OW","OF","SQ","UN","UT"
            # 6 bytes total (2 reserved bytes preceeding the 4 byte value length)
            reserved = 2
            bytes = 4
          when ITEM_VR
            # For the item elements: "FFFE,E000", "FFFE,E00D" and "FFFE,E0DD":
            bytes = 4
          else
            # For all the other element vr, value length is 2 bytes:
            bytes = 2
        end
      else
        # *****IMPLICIT*****:
        bytes = 4
      end
      # Handle skips and read out length value:
      @stream.skip(reserved)
      if bytes == 2
        length = @stream.decode(bytes, "US") # (2)
      else
        length = @stream.decode(bytes, "SL") # (4)
      end
      if length%2 > 0 and length > 0
        # According to the DICOM standard, all data element lengths should be an even number.
        # If it is not, it may indicate a file that is not standards compliant or it might even not be a DICOM file.
        @msg << "Warning: Odd number of bytes in data element's length occured. This is a violation of the DICOM standard, but program will attempt to read the rest of the file anyway."
      end
      return vr, length
    end

    # Reads and returns the binary value string of a Data Element (varying length).
    #
    def read_bin(length)
      return @stream.extract(length)
    end

    # Reads and returns the decoded Data Element VALUE (varying length).
    # NB! For some cases (pixel data, compressed data, unknown data), a value is not processed (nil is returned).
    #
    def read_value(vr, length)
      unless vr == "OW" or vr == "OB" or vr == "OF" or vr == "UN"
        # Since the binary string has already been extracted for this Data Element, we must first "rewind":
        @stream.skip(-length)
        # Decode data:
        value = @stream.decode(length, vr)
        # If the returned value is an array of multiple elements, we will join it to a string with the separator "\":
        value = value.join("\\") if value.is_a?(Array)
      else
        # No decoded value:
        value = nil
      end
      return value
    end

    # Tests if the file is readable and opens it.
    #
    def open_file(file)
      if File.exist?(file)
        if File.readable?(file)
          if not File.directory?(file)
            if File.size(file) > 8
              @file = File.new(file, "rb")
            else
              @msg << "Error! File is too small to contain DICOM information (#{file})."
            end
          else
            @msg << "Error! File is a directory (#{file})."
          end
        else
          @msg << "Error! File exists but I don't have permission to read it (#{file})."
        end
      else
        @msg << "Error! The file you have supplied does not exist (#{file})."
      end
    end

    # Registers an unexpected error by toggling a success boolean and recording an error message.
    # The DICOM data stream has ended abruptly in such a way that a Data Element's value was shorter than expected.
    #
    def set_abrupt_error
      @msg << "Error! The parsed data of the last Data Element #{@current_element.tag} does not match it's specified length value. This is probably the result of invalid or corrupt DICOM data."
      @success = false
    end

    # Changes encoding variables as the file reading proceeds past the initial Meta Group (0002,xxxx) of the DICOM file.
    #
    def switch_syntax
      # Get the transfer syntax string, unless it has already been provided by keyword:
      unless @transfer_syntax
        ts_element = @obj["0002,0010"]
        if ts_element
          @transfer_syntax = ts_element.value
        else
          @transfer_syntax = IMPLICIT_LITTLE_ENDIAN
        end
      end
      # Query the library with our particular transfer syntax string:
      valid_syntax, @rest_explicit, @rest_endian = LIBRARY.process_transfer_syntax(@transfer_syntax)
      unless valid_syntax
        @msg << "Warning: Invalid/unknown transfer syntax! Will try reading the file, but errors may occur."
      end
      # We only plan to run this method once:
      @switched = true
      # Update endian, explicitness and unpack variables:
      @switched_endian = true if @rest_endian != @file_endian
      @file_endian = @rest_endian
      @stream.set_endian(@rest_endian)
      @explicit = @rest_explicit
    end


    # Initiates the variables that are used during file reading.
    #
    def init_variables
      # Some variables that will be made available to the DObject class:
      # Array that will holde any messages generated while reading the DICOM file:
      @msg = Array.new
      # Variables that contain properties of the DICOM file:
      # Presence of the official DICOM signature:
      @signature = false
      # Default explicitness of start of DICOM file::
      @explicit = true
      # Default endianness of start of DICOM files is little endian:
      @file_endian = false
      @switched_endian = false
      # Variables used internally when parsing the DICOM string:
      @header_length = 0
      # Explicitness of the remaining groups after the initial 0002 group:
      @rest_explicit = false
      # Endianness of the remaining groups after the first group:
      @rest_endian = false
      # When the file switch from group 0002 to a later group we will update encoding values, and this switch will keep track of that:
      @switched = false
      # Keeping track of the data element parent status while parsing the DICOM string:
      @current_parent = @obj
      @current_element = @obj
      # Items contained under the pixel data element may contain data directly, so we need a variable to keep track of this:
      @enc_image = false
      # Assume header size is zero bytes until otherwise is determined:
      @header_length = 0
      # Assume file will be read successfully and toggle it later if we experience otherwise:
      @success = true
    end

  end # of class
end # of module
