module Fleximage
  
  # Container for Fleximage model method inclusion modules
  module Model
    
    class MasterImageNotFound < RuntimeError #:nodoc:
    end
    
    # Include acts_as_fleximage class method
    def self.included(base) #:nodoc:
      base.extend(ClassMethods)
    end
    
    # Provides class methods for Fleximage for use in model classes.  The only class method is
    # acts_as_fleximage which integrates Fleximage functionality into a model class.
    #
    # The following class level accessors also get inserted.
    #
    # * +image_directory+: (String, no default) Where the master images are stored, directory path relative to your 
    #   app root.
    # * +use_creation_date_based_directories+: (Boolean, default +true+) If true, master images will be stored in
    #   directories based on creation date.  For example: <tt>"#{image_directory}/2007/11/24/123.png"</tt> for an
    #   image with an id of 123 and a creation date of November 24, 2007.  Turing this off would cause the path
    #   to be "#{image_directory}/123.png" instead.  This helps keep the OS from having directories that are too 
    #   full.
    # * +image_storage_format+: (:png or :jpg, default :png) The format of your master images.  Using :png will give 
    #   you the best quality, since the master images as stored as lossless version of the original upload.  :jpg 
    #   will apply lossy compression, but the master image file sizes will be much smaller.  If storage space is a 
    #   concern, us :jpg.
    # * +require_image+: (Boolean, default +true+) The model will raise a validation error if no image is uploaded
    #   with the record.  Setting to false allows record to be saved with no images.
    # * +missing_image_message+: (String, default "is required") Validation message to display when no image was uploaded for 
    #   a record.
    # * +invalid_image_message+: (String default "was not a readable image") Validation message when an image is uploaded, but is not an 
    #   image format that can be read by RMagick.
    # * +output_image_jpg_quality+: (Integer, default 85) When rendering JPGs, this represents the amount of
    #   compression.  Valid values are 0-100, where 0 is very small and very ugly, and 100 is near lossless but
    #   very large in filesize.
    # * +default_image_path+: (String, nil default) If no image is present for this record, the image at this path will be
    #   used instead.  Useful for a placeholder graphic for new content that may not have an image just yet.
    # * +preprocess_image+: (Block, no default) Call this class method just like you would call +operate+ in a view.
    #   The image transoformation in the provided block will be run on every uploaded image before its saved as the 
    #   master image.
    #
    # Example:
    #
    #   class Photo < ActiveRecord::Base
    #     acts_as_fleximage do 
    #       image_directory 'public/images/uploaded'
    #       use_creation_date_based_directories true
    #       image_storage_format      :png
    #       require_image             true
    #       missing_image_message     'is required'
    #       invalid_image_message     'was not a readable image'
    #       default_image_path        'public/images/no_photo_yet.png'
    #       output_image_jpg_quality  85
    #       
    #       preprocess_image do |image|
    #         image.resize '1024x768'
    #       end
    #     end
    #   
    #     # normal model methods...
    #   end
    module ClassMethods
      
      # Use this method to include Fleximage functionality in your model.  It takes an 
      # options hash with a single required key, :+image_directory+.  This key should 
      # point to the directory you want your images stored on your server.  Or
      # configure with a nice looking block.
      def acts_as_fleximage(options = {})
        
        # Include the necesary instance methods
        include Fleximage::Model::InstanceMethods
        
        # Call this class method just like you would call +operate+ in a view.
        # The image transoformation in the provided block will be run on every uploaded image before its saved as the 
        # master image.
        def self.preprocess_image(&block)
          preprocess_image_operation(block)
        end
        
        # Internal method to ask this class if it stores image in the DB.
        def self.db_store?
          columns.find do |col|
            col.name == 'image_file_data'
          end
        end
        
        # validation callback
        validate :validate_image
        
        # The filename of the temp image.  Used for storing of good images when validation fails
        # and the form needs to be redisplayed.
        attr_reader :image_file_temp
        
        # Where images get stored
        dsl_accessor :image_directory
        
        # Put uploads from different days into different subdirectories
        dsl_accessor :use_creation_date_based_directories, :default => true
        
        # The format are master images are stored in
        dsl_accessor :image_storage_format, :default => Proc.new { :png }
        
        # Require a valid image.  Defaults to true.  Set to false if its ok to have no image for
        dsl_accessor :require_image, :default => true
        
        # Missing image message
        dsl_accessor :missing_image_message, :default => 'is required'
        
        # Invalid image message
        dsl_accessor :invalid_image_message, :default => 'was not a readable image'
        
        # Sets the quality of rendered JPGs
        dsl_accessor :output_image_jpg_quality, :default => 85
        
        # Set a default image to use when no image has been assigned to this record
        dsl_accessor :default_image_path
        
        # A block that processes an image before it gets saved as the master image of a record.
        # Can be helpful to resize potentially huge images to something more manageable. Set via
        # the "preprocess_image { |image| ... }" class method.
        dsl_accessor :preprocess_image_operation
        
        # Image related save and destroy callbacks
        after_destroy :delete_image_file
        before_save   :pre_save
        after_save    :post_save
        
        # execute configuration block
        yield if block_given?
        
        # set the image directory from passed options
        image_directory options[:image_directory] if options[:image_directory]
        
        # Require the declaration of a master image storage directory
        if !image_directory && !db_store?
          raise "No place to put images!  Declare this via the :image_directory => 'path/to/directory' option\n"+
                "Or add a database column named image_file_data for DB storage"
        end
      end
    end
    
    # Provides methods that every model instance that acts_as_fleximage needs.
    module InstanceMethods
      
      # Returns the path to the master image file for this record.
      #   
      #   @some_image.directory_path #=> /var/www/myapp/uploaded_images
      #
      # If this model has a created_at field, it will use a directory 
      # structure based on the creation date, to prevent hitting the OS imposed
      # limit on the number files in a directory.
      #
      #   @some_image.directory_path #=> /var/www/myapp/uploaded_images/2008/3/30
      def directory_path
        raise 'No image directory was defined, cannot generate path' unless self.class.image_directory
        
        # base directory
        directory = "#{RAILS_ROOT}/#{self.class.image_directory}"
        
        # specific creation date based directory suffix.
        creation = self[:created_at] || self[:created_on]
        if self.class.use_creation_date_based_directories && creation 
          "#{directory}/#{creation.year}/#{creation.month}/#{creation.day}"
        else
          directory
        end
      end
      
      # Returns the path to the master image file for this record.
      #   
      #   @some_image.file_path #=> /var/www/myapp/uploaded_images/123.png
      def file_path
        "#{directory_path}/#{id}.#{self.class.image_storage_format}"
      end
      
      # Sets the image file for this record to an uploaded file.  This can 
      # be called directly, or passively like from an ActiveRecord mass 
      # assignment.
      # 
      # Rails will automatically call this method for you, in most of the 
      # situations you would expect it to.
      #
      #   # via mass assignment, the most common form you'll probably use
      #   Photo.new(params[:photo])
      #   Photo.create(params[:photo])
      #
      #   # via explicit assignment hash
      #   Photo.new(:image_file => params[:photo][:image_file])
      #   Photo.create(:image_file => params[:photo][:image_file])
      #   
      #   # Direct Assignment, usually not needed
      #   photo = Photo.new
      #   photo.image_file = params[:photo][:image_file]
      #   
      #   # via an association proxy
      #   p = Product.find(1)
      #   p.images.create(params[:photo])
      def image_file=(file)
        # Get the size of the file.  file.size works for form-uploaded images, file.stat.size works
        # for file object created by File.open('foo.jpg', 'rb')
        file_size = file.respond_to?(:size) ? file.size : file.stat.size
        
        if file.respond_to?(:read) && file_size > 0
          
          # Create RMagick Image object from uploaded file
          if file.path
            @uploaded_image = Magick::Image.read(file.path).first
          else
            @uploaded_image = Magick::Image.from_blob(file.read).first
          end
          
          set_magic_attributes(file)
          
          # Success, make sure everything is valid
          @invalid_image = false
          save_temp_image(file) unless @dont_save_temp
        end
      rescue Magick::ImageMagickError => e
        error_strings = [
          'Improper image header',
          'no decode delegate for this image format',
          'UnableToOpenBlob'
        ]
        if e.to_s =~ /#{error_strings.join('|')}/
          @invalid_image = true
        else
          raise e
        end
      end
      
      # Assign the image via a URL, which will make the plugin go
      # and fetch the image at the provided URL.  The image will be stored
      # locally as a master image for that record from then on.  This is 
      # intended to be used along side the image upload to allow people the
      # choice to upload from their local machine, or pull from the internet.
      #
      #   @photo.image_file_url = 'http://foo.com/bar.jpg'
      def image_file_url=(file_url)
        @image_file_url = file_url
        if file_url =~ %r{^https?://}
          file = open(file_url)
          
          # Force a URL based file to have an original_filename
          eval <<-CODE
            def file.original_filename
              "#{file_url}"
            end
          CODE
          
          self.image_file = file
          
        elsif file_url.empty?
          # Nothing to process, move along
          
        else
          # invalid URL, raise invalid image validation error
          @invalid_image = true
        end
      end
      
      # Sets the uploaded image to the name of a file in RAILS_ROOT/tmp that was just
      # uploaded.  Use as a hidden field in your forms to keep an uploaded image when
      # validation fails and the form needs to be redisplayed
      def image_file_temp=(file_name)
        if !@uploaded_image && file_name && file_name.any?
          @image_file_temp = file_name
          file_path = "#{RAILS_ROOT}/tmp/fleximage/#{file_name}"
          
          @dont_save_temp = true
          if File.exists?(file_path)
            File.open(file_path, 'rb') do |f|
              self.image_file = f
            end
          end
          @dont_save_temp = false
        end
      end
      
      # Return the @image_file_url that was previously assigned.  This is not saved
      # in the database, and only exists to make forms happy.
      def image_file_url
        @image_file_url
      end
      
      # Return true if this record has an image.
      def has_image?
        @uploaded_image || @output_image || has_saved_image?
      end
      
      def has_saved_image?
        self.class.db_store? ? !!image_file_data : File.exists?(file_path)
      end
      
      # Call from a .flexi view template.  This enables the rendering of operators 
      # so that you can transform your image.  This is the method that is the foundation
      # of .flexi views.  Every view should consist of image manipulation code inside a
      # block passed to this method. 
      #
      #   # app/views/photos/thumb.jpg.flexi
      #   @photo.operate do |image|
      #     image.resize '320x240'
      #   end
      def operate(&block)
        returning self do
          proxy = ImageProxy.new(load_image, self)
          block.call(proxy)
          @output_image = proxy.image
        end
      end
      
      # Load the image from disk/DB, or return the cached and potentially 
      # processed output image.
      def load_image #:nodoc:
        @output_image ||= @uploaded_image
        
        # Return the current image if we have loaded it already
        return @output_image if @output_image
        
        # Load the image from disk
        if self.class.db_store?
          if image_file_data && image_file_data.any?
            @output_image = Magick::Image.from_blob(image_file_data).first
          else
            master_image_not_found
          end
        else
          @output_image = Magick::Image.read(file_path).first
        end
        
      rescue Magick::ImageMagickError => e
        if e.to_s =~ /unable to open file/
          master_image_not_found
        else
          raise e
        end
      end
      
      # Convert the current output image to a jpg, and return it in binary form.  options support a
      # :format key that can be :jpg, :gif or :png
      def output_image(options = {}) #:nodoc:
        format = (options[:format] || :jpg).to_s.upcase
        @output_image.format = format
        @output_image.strip!
        if format = 'JPG'
          quality = self.class.output_image_jpg_quality
          @output_image.to_blob { self.quality = quality }
        else
          @output_image.to_blob
        end
      ensure
        GC.start
      end
      
      # Delete the image file for this record. This is automatically ran after this record gets 
      # destroyed, but you can call it manually if you want to remove the image from the record.
      def delete_image_file
        File.delete(file_path) if (!self.class.db_store? && File.exists?(file_path))
      end
      
      # Execute image presence and validity validations.
      def validate_image #:nodoc:
        field_name = (@image_file_url && @image_file_url.any?) ? :image_file_url : :image_file
                
        if @invalid_image
          errors.add field_name, self.class.invalid_image_message
        elsif self.class.require_image && !has_image?
          errors.add field_name, self.class.missing_image_message
        end
      end
      
      private
        # Perform pre save tasks.  Preprocess the image, and write it to DB.
        def pre_save
          if @uploaded_image
            # perform preprocessing
            perform_preprocess_operation
            
            # Convert to storage format
            @uploaded_image.format = self.class.image_storage_format.to_s.upcase
            
            # Write image data to the DB field
            if self.class.db_store?
              self.image_file_data = @uploaded_image.to_blob
            end
          end
        end
        
        # Write image to file system and cleanup garbage.
        def post_save
          if @uploaded_image && !self.class.db_store?
            # Make sure target directory exists
            FileUtils.mkdir_p(directory_path)
          
            # Write master image file
            @uploaded_image.write(file_path)
          end
          
          # Cleanup temp files
          delete_temp_image

          # Start GC to close up memory leaks
          GC.start if @uploaded_image
        end
        
        # Preprocess this image before saving
        def perform_preprocess_operation
          if self.class.preprocess_image_operation
            operate(&self.class.preprocess_image_operation)
            set_magic_attributes #update width and height magic columns
            @uploaded_image = @output_image
          end
        end
        
        # If any magic column names exists fill them with image meta data.
        def set_magic_attributes(file = nil)
          if file && self.respond_to?(:image_filename=)
            filename = file.original_filename if file.respond_to?(:original_filename)
            filename = file.basename          if file.respond_to?(:basename)
            self.image_filename = filename
          end
          self.image_width    = @uploaded_image.columns if self.respond_to?(:image_width=)
          self.image_height   = @uploaded_image.rows    if self.respond_to?(:image_height=)
        end
        
        # Save the image in the rails tmp directory
        def save_temp_image(file)
          file_name = file.respond_to?(:original_filename) ? file.original_filename : file.path
          @image_file_temp = file_name.split('/').last
          path = "#{RAILS_ROOT}/tmp/fleximage"
          FileUtils.mkdir_p(path)
          File.open("#{path}/#{@image_file_temp}", 'w') do |f|
            file.rewind
            f.write file.read
          end
        end
        
        # Delete the temp image after its no longer needed
        def delete_temp_image
          FileUtils.rm_rf "#{RAILS_ROOT}/tmp/fleximage/#{@image_file_temp}"
        end
        
        # Load the default image, or raise an expection
        def master_image_not_found
          # Load the default image
          if self.class.default_image_path
            @output_image = Magick::Image.read("#{RAILS_ROOT}/#{self.class.default_image_path}").first
          
          # No default, not master image, so raise exception
          else
            message = "Master image was not found for this record"
            
            if !self.class.db_store?
              message << "\nExpected image to be at:"
              message << "\n  #{file_path}"
            end
            
            raise MasterImageNotFound, message
          end
        end
    end
    
  end
end
