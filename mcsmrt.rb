# -*- coding: utf-8 -*-
require 'bio'
require 'trollop'

#USAGE: ruby mcsmrt.rb -i #{all_bc_reads_input_file} -e 1 -c ../rdp_gold.fa -t ../16s_ncbi_database/16s_lineage_short_species_name_reference_database.udb -l ../16s_ncbi_database/16sMicrobial_ncbi_lineage.fasta -g ../human_g1k_v37.fasta -p ../primers.fasta

##### Input 
opts = Trollop::options do
  opt :allReadsInputFile, "File with all the reads which are barcoded and has ccs passes", :type => :string, :short => "-i"
  opt :eevalue, "Expected error at which you want filtering to take place", :type => :string, :short => "-e"
  opt :uchimedbfile, "Path to database file for the uchime command", :type => :string, :short => "-c"
  opt :utaxdbfile, "Path to database file for the utax command", :type => :string, :short => "-t"
  opt :lineagefastafile, "Path to FASTA file with lineage info for the ublast command", :type => :string, :short => "-l"
  opt :host_db, "Path to fasta file of host genome", :type => :string, :short => "-g"
  opt :primerfile, "Path to fasta file with the primer sequences", :type => :string, :short => "-p"
end 

##### Assigning variables to the input and making sure we got all the inputs
opts[:allReadsInputFile].nil? ==false  ? all_bc_reads_file = opts[:allReadsInputFile] : abort("Must supply the file with all barcoded reads and ccs pass counts with '-i'")
opts[:eevalue].nil?           ==false  ? ee = opts[:eevalue]                           : abort("Must supply an Expected Error value with '-e'")
opts[:uchimedbfile].nil?      ==false  ? uchime_db_file = opts[:uchimedbfile]          : abort("Must supply a 'uchime database file' e.g. rdpgold.udb with '-c'")
opts[:utaxdbfile].nil?        ==false  ? utax_db_file = opts[:utaxdbfile]              : abort("Must supply a 'utax database file' e.g. 16s_ncbi.udb with '-t'")
opts[:lineagefastafile].nil?  ==false  ? lineage_fasta_file = opts[:lineagefastafile]  : abort("Must supply a 'lineage fasta file' e.g. ncbi_lineage.fasta (for blast) with '-l'")
opts[:host_db].nil?           ==false  ? human_db = opts[:host_db]                     : abort("Must supply a fasta of the host genome e.g. human_g1k.fasta with '-g'")
opts[:primerfile].nil?        ==false  ? primer_file = opts[:primerfile]               : abort("Must supply a fasta of the primer sequences e.g primer_seqs.fa with '-p'")

##### Making sure we can open the file with all barcoded reads
abort("Can't open the file with all barcoded reads!") if !File.exist?(all_bc_reads_file)

##### Get the path to the directory in which the scripts exist 
script_directory = File.dirname(__FILE__)

##### Class that stores information about each record from the reads file
class Read_sequence
  attr_accessor :read_name, :basename, :ccs, :barcode, :sample, :ee_pretrim, :ee_posttrim, :length_pretrim, :length_posttrim, :host_map, :f_primer_matches, :r_primer_matches, :f_primer_start, :f_primer_end, :r_primer_start, :r_primer_end, :read_orientation, :primer_note, :half_primer_match

  def initialize
    @read_name = "" 
    @basename = ""
    @ccs = 0
    @barcode = "" 
    @sample = "" 
    @ee_pretrim = 0.0 
    @ee_posttrim = 0.0 
    @length_pretrim = 0
    @length_posttrim = 0
    @host_map = false 
    @f_primer_matches = false
    @r_primer_matches = false
    @f_primer_start = 0
    @f_primer_end = 0
    @r_primer_start = 0
    @r_primer_end = 0
    @read_orientation = ""
    @primer_note = ""
    @half_primer_match = "NA"
  end
end

##################### METHODS #######################

##### Method to write reads in fastq format
#fh = File handle, header = read header (string), sequence = read sequence, quality = phred quality scores
def write_to_fastq (fh, header, sequence, quality)
=begin
  fh       = file handle
  header   = string
  sequence = string
  quality  = array
=end
  fh.write('@' + header + "\n")
  fh.write(sequence)
  fh.write("\n+\n")
  fh.write(quality + "\n")
end

##### Method whcih takes an fq file as argument and returns a hash with the read name and ee
def get_ee_from_fq_file (file, ee, suffix)
	file_basename = File.basename(file, ".*")
	
	#puts file_basename
	`usearch -fastq_filter #{file} -fastqout #{file_basename}_#{suffix} -fastq_maxee 20000 -fastq_qmax 75 -fastq_eeout -sample all`
	
	# Hash that is returned from this method (read name - key, ee - value)
	ee_hash = {}
	
	# Open the file from fastq_filter command and process it
	ee_filt_file = Bio::FlatFile.auto("#{file_basename}_#{suffix}")
	ee_filt_file.each do |entry|
		entry_def_split = entry.definition.split(";")
		read_name = entry_def_split[0].split("@")[0]
		ee = entry.definition.match(/ee=(.*);/)[1]
		ee_hash[read_name] = ee.to_f
	end
	
	return ee_hash
end

##### Mapping reads to the human genome
def map_to_human_genome (file, human_db)   
	file_basename = File.basename(file, ".*")
	                                                                                                            
 	#align all reads to the human genome                                                                                                                   
  `bwa mem -t 15 #{human_db} #{file} > #{file_basename}_host_map.sam`
  
  #sambamba converts sam to bam format                                                                                                                   
  `sambamba view -S -f bam #{file_basename}_host_map.sam -o #{file_basename}_host_map.bam`
  
  #Sort the bam file                                                                                                                                     
  `sambamba sort -t15 -o #{file_basename}_host_map_sorted.bam #{file_basename}_host_map.bam`
  
  #filter the bam for only ‘not unmapped’ reads -> reads that are mapped                                                                                 
  `sambamba view -F 'not unmapped' #{file_basename}_host_map.bam > #{file_basename}_host_map_mapped.txt`
  mapped_count = `cut -d ';' -f1 #{file_basename}_host_map_mapped.txt| sort | uniq | wc -l`
	mapped_string = `cut -d ';' -f1 #{file_basename}_host_map_mapped.txt`
  
  #filter reads out for ‘unmapped’ -> we would use these for pipeline                                                                             
  `sambamba view -F 'unmapped' #{file_basename}_host_map.bam > #{file_basename}_host_map_unmapped.txt`
  
  #convert the sam file to fastq                                                                                                                         
  `grep -v ^@ #{file_basename}_host_map_unmapped.txt | awk '{print \"@\"$1\"\\n\"$10\"\\n+\\n\"$11}' > #{file_basename}_host_map_unmapped.fq`
  
 	return mapped_count, mapped_string
end

##### Method for primer matching 
def primer_match (script_directory, fastq_file, primer_file)
	file_basename = File.basename(fastq_file, ".*")
	
	# Run the usearch command for primer matching
  `usearch -search_oligodb #{fastq_file} -db #{primer_file} -strand both -userout #{file_basename}_primer_map.txt -userfields query+target+qstrand+diffs+tlo+thi+qlo+qhi`                                                                                                    

  # Run the script which parses the primer matching output
  `ruby #{script_directory}/primer_matching.rb -p #{file_basename}_primer_map.txt -o #{file_basename}_primer_info.txt` 
  	
  # Open the file with parsed primer matching results
  "#{file_basename}_primer_info.txt".nil? ==false  ? primer_matching_parsed_file = File.open("#{file_basename}_primer_info.txt") : abort("Primer mapping parsed file was not created from primer_matching.rb")

  return_hash = {}
  primer_matching_parsed_file.each_with_index do |line, index|
  	if index == 0
  		next
  	else
  		line_split = line.chomp.split("\t")
  		key = line_split[0]
  		return_hash[key] = Array.new(line_split[1..-1].length)
  		if line_split[1] == "true"
  			return_hash[key][0] = true
  		else
  			return_hash[key][0] = false
  		end
  		if line_split[2] == "true"
  			return_hash[key][1] = true
  		else
  			return_hash[key][1] = false
  		end
  		  return_hash[key][2..-1] = line_split[3..-1]
  		end
  	end

  return return_hash

end

def create_half_primer_files (primer_file_path)
  # Open the primer file
  primer_file = Bio::FlatFile.auto(primer_file_path, "r")
  
  # Get the database files with half forward and reverse from the primerfastafile
  out_fow_half = File.open("primer_half_fow.fasta", "w")
  out_rev_half = File.open("primer_half_rev.fasta", "w")
  
  primer_file.each do |entry|
    if entry.definition.include?("forward")
      half_len = entry.naseq.length/2
      # print to forward out
      out_fow_half.puts(">"+entry.definition)
      out_fow_half.puts(entry.naseq.upcase[0..half_len])
      # print to reverse out
      out_rev_half.puts(">"+entry.definition)
      out_rev_half.puts(entry.naseq.upcase)
    elsif entry.definition.include?("reverse")
      half_len = entry.naseq.length/2
      # print to forward out
      out_fow_half.puts(">"+entry.definition)
      out_fow_half.puts(entry.naseq.upcase)
      # print to reverse out
      out_rev_half.puts(">"+entry.definition)
      out_rev_half.puts(entry.naseq.upcase[0..half_len])
    end
  end
  
  out_fow_half.close
  out_rev_half.close
  
  # Check to see if the files were created properly
  abort("!!!!The file primer_half_rev (required for primer matching with half the reverse primer sequence) does not exist!!!!") if !File.exists?("primer_half_rev.fasta")
  abort("!!!!The file primer_half_rev (required for primer matching with half the reverse primer sequence) is empty!!!!") if File.zero?("primer_half_rev.fasta")
  abort("!!!!The file primer_half_fow (required for primer matching with half the forward primer sequence) does not exist!!!!") if !File.exists?("primer_half_fow.fasta")
  abort("!!!!The file primer_half_fow (required for primer matching with half the forward primer sequence) is empty!!!!") if File.zero?("primer_half_fow.fasta")
  
end 

##### Method to retrieve singletons
def retrieve_singletons (script_directory, seqs_hash, singletons_hash, fastq_file)
  file_basename = File.basename(fastq_file, ".*")

  #Create separate fq files for the ones missing the forward or reverse macthes!
  fh1 = File.open("#{file_basename}_singletons_forward_missing.fq", "w")
  fh2 = File.open("#{file_basename}_singletons_reverse_missing.fq", "w")

  # Loop through the singletons hash
	singletons_hash.each do |k, v|
    # Check to see which reads match to the full primers and which doesn't... 
		if v[0] == false 
      #puts seqs_hash[k][0], seqs_hash[k][1]
      write_to_fastq(fh1, k, seqs_hash[k][0], seqs_hash[k][1])
    elsif v[1] == false
      write_to_fastq(fh2, k, seqs_hash[k][0], seqs_hash[k][1])
    end
	end

  fh1.close
  fh2.close

  # Check to see if the fq files with sequences from singletons were created properly
  abort("!!!!The fq file singletons forward missing does not exist!!!!") if !File.exists?("#{file_basename}_singletons_forward_missing.fq")
  abort("!!!!The fq file singletons forward missing is empty!!!!") if File.zero?("#{file_basename}_singletons_forward_missing.fq")
  abort("!!!!The fq file singletons reverse missing does not exist!!!!") if !File.exists?("#{file_basename}_singletons_reverse_missing.fq")
  abort("!!!!The fq file singletons reverse missing is empty!!!!") if File.zero?("#{file_basename}_singletons_reverse_missing.fq")

  # Run the usearch command for primer matching with half the forward or half the reverse primer seqs
  `usearch -search_oligodb #{file_basename}_singletons_forward_missing.fq -db primer_half_fow.fasta -strand both -userout #{file_basename}_forward_missing_primer_map.txt -userfields query+target+qstrand+diffs+tlo+thi+qlo+qhi`
  `usearch -search_oligodb #{file_basename}_singletons_reverse_missing.fq -db primer_half_rev.fasta -strand both -userout #{file_basename}_reverse_missing_primer_map.txt -userfields query+target+qstrand+diffs+tlo+thi+qlo+qhi`

  # Run the primer matching script on these 2 primer matching results
  `ruby #{script_directory}/primer_matching.rb -p #{file_basename}_forward_missing_primer_map.txt -o #{file_basename}_forward_missing_primer_info.txt` 
  `ruby #{script_directory}/primer_matching.rb -p #{file_basename}_reverse_missing_primer_map.txt -o #{file_basename}_reverse_missing_primer_info.txt` 

  # Open the files with parsed primer matching results
  "#{file_basename}_forward_missing_primer_info.txt".nil? == false  ? primer_matching_fm_parsed_file = File.open("#{file_basename}_forward_missing_primer_info.txt") : abort("Primer mapping parsed file for forward primer missing was not created from primer_matching.rb")
  "#{file_basename}_reverse_missing_primer_info.txt".nil? == false  ? primer_matching_rm_parsed_file = File.open("#{file_basename}_reverse_missing_primer_info.txt") : abort("Primer mapping parsed file for reverse primer missing was not created from primer_matching.rb")
  
  return_hash_fm = {}
  return_hash_rm = {}

  primer_matching_fm_parsed_file.each_with_index do |line, index|
    if index == 0
      next
    else
      line_split = line.chomp.split("\t")
      key = line_split[0]
      seq_length = seqs_hash[key][1].length
      #puts seqs_hash["m151002_181152_42168_c100863312550000001823190302121650_s1_p0/33682/ccs"][1].length
      if line_split[1] == "true" and line_split[2] == "true" and line_split[7] == "+" and line_split[3].to_i <= 100 and line_split[5].to_i >= seq_length-100
        return_hash_fm[key] = true
      elsif line_split[1] == "true" and line_split[2] == "true" and line_split[7] == "-" and line_split[3].to_i >= seq_length-100 and line_split[5].to_i <= 100
        return_hash_fm[key] = true
      else
        return_hash_fm[key] = false
      end
    end
  end

  primer_matching_rm_parsed_file.each_with_index do |line, index|
    if index == 0
      next
    else
      line_split = line.chomp.split("\t")
      key = line_split[0]
      seq_length = seqs_hash[key][1].length
      if line_split[1] == "true" and line_split[2] == "true" and line_split[7] == "+" and line_split[3].to_i <= 100 and line_split[5].to_i >= seq_length-100
        return_hash_fm[key] = true
      elsif line_split[1] == "true" and line_split[2] == "true" and line_split[7] == "-" and line_split[3].to_i >= seq_length-100 and line_split[5].to_i <= 100
        return_hash_rm[key] = true
      else
        return_hash_rm[key] = false
      end
    end
  end

  return return_hash_fm, return_hash_rm
end 


##### Work with the file which has all the reads
def process_all_bc_reads_file (script_directory, all_bc_reads_file, all_reads_hash, ee, human_db, primer_file)
  # Opening the file with all original reads for writing with bio module
  all_bc_reads = Bio::FlatFile.auto(all_bc_reads_file)
  
  # Create a sequence hash which has all the sequence and quality strings for each record
  seqs_hash = {}
  
  # Loop through the fq file 
  all_bc_reads.each do |entry|
    # Fill the all_bc_hash with some basic info that we can get (read_name, barcode, ccs, length_pretrim)
    def_split = entry.definition.split(";")
    read_name = def_split[0]
    #puts def_split
    
    if def_split[1].include?("barcodelabel")
      basename = def_split[1].split("=")[1]
      barcode = basename.split("_")[0]
      sample = basename.split("_")[1..-1].join("_")
      ccs = def_split[2].split("=")[1].to_i
    elsif def_split[1].include?("ccs")
      basename = def_split[2].split("=")[1]
      barcode = basename.split("_")[0]
      sample = basename.split("_")[1..-1].join("_")
      ccs = def_split[1].split("=")[1].to_i
    else
      puts "Header does not have barcode label and ccs counts!"
    end
    all_reads_hash[read_name] = Read_sequence.new
    all_reads_hash[read_name].read_name = read_name
    all_reads_hash[read_name].basename = basename
    all_reads_hash[read_name].ccs = ccs
    all_reads_hash[read_name].barcode = barcode
    all_reads_hash[read_name].sample = sample
    all_reads_hash[read_name].length_pretrim = entry.naseq.size
#TODO: Add in the primer matching step here, to keep from having to read throught he entire hash again
#Have to have the primer matched info, to calculate singleton primers    

    # Populate the s
    seqs_hash[read_name] = [entry.naseq.upcase, entry.quality_string]
    
  end
  
  # Get ee_pretrim
  ee_pretrim_hash = get_ee_from_fq_file(all_bc_reads_file, ee, "ee_pretrim.fq")
  #puts ee_pretrim_hash
  ee_pretrim_hash.each do |k, v|
    #puts all_reads_hash[k]
    all_reads_hash[k].ee_pretrim = v
  end
  
  # Get the seqs which map to the host genome
  mapped_count, mapped_string = map_to_human_genome(all_bc_reads_file, human_db) 
  #puts mapped_string.inspect	

	# Primer matching
	count_no_primer_match = 0
  primer_record_hash = primer_match(script_directory, all_bc_reads_file, primer_file)
  #puts primer_record_hash.inspect

  # Fill the all info hash with host mapping, primer macthing info!
  # Get the records which are singletons (which map to only one primer)
  singletons_hash = {}
  all_reads_hash.each do |k, v|
  	# Store the host genome mapping info
  	if mapped_string.include?(k)
			all_reads_hash[k].host_map = true
		end	
  	# Store the primer matching info
  	if primer_record_hash.key?(k)
  		all_reads_hash[k].f_primer_matches = primer_record_hash[k][0]
  		all_reads_hash[k].r_primer_matches = primer_record_hash[k][1]
  		all_reads_hash[k].f_primer_start = primer_record_hash[k][2].to_i
  		all_reads_hash[k].f_primer_end = primer_record_hash[k][3].to_i
  		all_reads_hash[k].r_primer_start = primer_record_hash[k][4].to_i
  		all_reads_hash[k].r_primer_end = primer_record_hash[k][5].to_i
  		all_reads_hash[k].read_orientation = primer_record_hash[k][6]
      all_reads_hash[k].primer_note = primer_record_hash[k][7]
  		# Get singletons hash 
  		if primer_record_hash[k][0] == false or primer_record_hash[k][1] == false
  			singletons_hash[k] = [primer_record_hash[k][0], primer_record_hash[k][1]]
  		end
  	else
  		count_no_primer_match += 1
  		all_reads_hash[k].f_primer_matches = "NA"
  		all_reads_hash[k].r_primer_matches = "NA"
  		all_reads_hash[k].f_primer_start = "NA"
  		all_reads_hash[k].f_primer_end = "NA"
  		all_reads_hash[k].r_primer_start = "NA"
  		all_reads_hash[k].r_primer_end = "NA"
  		all_reads_hash[k].read_orientation = "NA" 
      all_reads_hash[k].primer_note = "no_primer_hits"
  	end
  end
  #puts all_reads_hash["m151002_181152_42168_c100863312550000001823190302121650_s1_p0/5872/ccs"].inspect # test for a sequence which maps to the host genome
  #puts count_no_primer_match
  #puts singletons_hash.length
  
  # Call the method which creates the primer files with half of the sequences
  create_half_primer_files(primer_file)
  
  # Call the method which retrieves singletons
  return_hash_fm, return_hash_rm = retrieve_singletons(script_directory, seqs_hash, singletons_hash, all_bc_reads_file)
  #puts return_hash_fm.length + return_hash_rm.length
  #puts return_hash_fm["m151002_181152_42168_c100863312550000001823190302121650_s1_p0/33682/ccs"].inspect

  # Add singletons info to the all read info hash
  all_reads_hash.each do |k, v|
    if return_hash_fm.key?(k) and return_hash_fm[k] == true
      all_reads_hash[k].half_primer_match = true
    elsif return_hash_fm.key?(k) and return_hash_fm[k] == false
      all_reads_hash[k].half_primer_match = false
    elsif return_hash_rm.key?(k) and return_hash_rm[k] == true
      all_reads_hash[k].half_primer_match = true
    elsif return_hash_rm.key?(k) and return_hash_rm[k] == false
      all_reads_hash[k].half_primer_match = false
    end
  end

end


##################### MAIN PROGRAM #######################

# Create the hash which is going to store all infor for each read using the Read_sequence class
all_reads_hash = {}
process_all_bc_reads_file(script_directory, all_bc_reads_file, all_reads_hash, ee, human_db, primer_file)
#puts all_reads_hash
#puts all_reads_hash["m151002_181152_42168_c100863312550000001823190302121650_s1_p0/33682/ccs"].inspect

# Write all the info to a file
file_basename = File.basename(all_bc_reads_file, ".*")
all_info_out_file = File.open("all_bc_reads_info.txt", "w")
all_info_out_file.puts("read_name\tbasename\tccs\tbarcode\tsample\tee_pretrim\tee_posttrim\tlength_pretrim\tlength_posttrim\thost_map\tf_primer_matches\tr_primer_matches\tf_primer_start\tf_primer_end\tr_primer_start\tr_primer_end\tread_orientation\tprimer_note\thalf_primer_match")

all_reads_hash.each do |k, v|
  all_info_out_file.puts("#{k}\t#{all_reads_hash[k].basename}\t#{all_reads_hash[k].ccs}\t#{all_reads_hash[k].barcode}\t#{all_reads_hash[k].sample}\t#{all_reads_hash[k].ee_pretrim}\t#{all_reads_hash[k].ee_posttrim}\t#{all_reads_hash[k].length_pretrim}\t#{all_reads_hash[k].length_posttrim}\t#{all_reads_hash[k].host_map}\t#{all_reads_hash[k].f_primer_matches}\t#{all_reads_hash[k].r_primer_matches}\t#{all_reads_hash[k].f_primer_start}\t#{all_reads_hash[k].f_primer_end}\t#{all_reads_hash[k].r_primer_start}\t#{all_reads_hash[k].r_primer_end}\t#{all_reads_hash[k].read_orientation}\t#{all_reads_hash[k].primer_note}\t#{all_reads_hash[k].half_primer_match}")
end
